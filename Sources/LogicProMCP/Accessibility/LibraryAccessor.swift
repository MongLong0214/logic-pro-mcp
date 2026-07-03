import ApplicationServices
import CoreGraphics
import Foundation

/// Logic Pro Library panel accessor.
///
/// Logic Pro 12's Library uses an AXBrowser widget with 2 columns of
/// AXStaticText elements:
/// - Column 1: instrument categories (Bass, Drums, Synthesizer, ...)
/// - Column 2: presets within the selected category
///
/// The AXStaticText elements do NOT respond to standard AX click or
/// selection APIs. The only reliable way to switch category/preset is
/// to inject real mouse events via CGEvent at the element's screen
/// coordinates.
// MARK: - T1 new recursive types

public enum LibraryNodeKind: String, Codable, Sendable, Equatable {
    case folder
    case leaf
    case truncated
    case probeTimeout
    case cycle
}

public struct LibraryNode: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let kind: LibraryNodeKind
    public let children: [LibraryNode]

    public init(name: String, path: String, kind: LibraryNodeKind, children: [LibraryNode]) {
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
    }
}

/// Injectable probe abstraction for `enumerateTree`.
///
/// Real production: wraps live AX reads + AX-native selection (AXSelectedChildren
/// + AXPress), fall-through CGEvent only if parent AXList lookup fails.
/// Tests: inject scripted tree responses for deterministic coverage.
public struct TreeProbe: Sendable {
    /// Return the ordered child names at the given tree path, OR nil on probe timeout.
    /// Empty array = leaf node with no children (this path is a leaf).
    public let childrenAt: @Sendable ([String]) async -> [String]?

    /// Return true if Logic Pro is still the focused app. False aborts scan with error.
    public let focusOK: @Sendable () async -> Bool

    /// Return true if external (non-scanner) mutation happened since last call.
    public let mutationSinceLastCheck: @Sendable () async -> Bool

    /// Sleep for the given milliseconds (mocked to no-op in tests).
    public let sleep: @Sendable (Int) async -> Void

    /// Return a stable identity for an element at path (for cycle-detection visited set).
    public let visitedHash: @Sendable ([String]) -> Int

    public init(
        childrenAt: @Sendable @escaping ([String]) async -> [String]?,
        focusOK: @Sendable @escaping () async -> Bool,
        mutationSinceLastCheck: @Sendable @escaping () async -> Bool,
        sleep: @Sendable @escaping (Int) async -> Void,
        visitedHash: @Sendable @escaping ([String]) -> Int
    ) {
        self.childrenAt = childrenAt
        self.focusOK = focusOK
        self.mutationSinceLastCheck = mutationSinceLastCheck
        self.sleep = sleep
        self.visitedHash = visitedHash
    }
}

public struct LibraryRoot: Codable, Sendable, Equatable {
    public let generatedAt: String
    public let scanDurationMs: Int
    public let measuredSettleDelayMs: Int
    public let selectionRestored: Bool
    public let truncatedBranches: Int
    public let probeTimeouts: Int
    public let cycleCount: Int
    public let nodeCount: Int
    public let leafCount: Int
    public let folderCount: Int
    public let candidatePatchCount: Int
    public let nonApplicablePatchCount: Int
    public let root: LibraryNode
    public let categories: [String]
    public let presetsByCategory: [String: [String]]
    public let skippedDirectoryCount: Int
    public let scanWarnings: [String]

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case scanDurationMs
        case measuredSettleDelayMs
        case selectionRestored
        case truncatedBranches
        case probeTimeouts
        case cycleCount
        case nodeCount
        case leafCount
        case folderCount
        case candidatePatchCount
        case nonApplicablePatchCount
        case root
        case categories
        case presetsByCategory
        case skippedDirectoryCount
        case scanWarnings
    }

    public init(
        generatedAt: String, scanDurationMs: Int, measuredSettleDelayMs: Int,
        selectionRestored: Bool,
        truncatedBranches: Int, probeTimeouts: Int, cycleCount: Int,
        nodeCount: Int, leafCount: Int, folderCount: Int,
        candidatePatchCount: Int? = nil, nonApplicablePatchCount: Int = 0,
        root: LibraryNode, categories: [String], presetsByCategory: [String: [String]],
        skippedDirectoryCount: Int = 0, scanWarnings: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.scanDurationMs = scanDurationMs
        self.measuredSettleDelayMs = measuredSettleDelayMs
        self.selectionRestored = selectionRestored
        self.truncatedBranches = truncatedBranches
        self.probeTimeouts = probeTimeouts
        self.cycleCount = cycleCount
        self.nodeCount = nodeCount
        self.leafCount = leafCount
        self.folderCount = folderCount
        self.candidatePatchCount = candidatePatchCount ?? leafCount
        self.nonApplicablePatchCount = nonApplicablePatchCount
        self.root = root
        self.categories = categories
        self.presetsByCategory = presetsByCategory
        self.skippedDirectoryCount = skippedDirectoryCount
        self.scanWarnings = scanWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try container.decode(String.self, forKey: .generatedAt)
        self.scanDurationMs = try container.decode(Int.self, forKey: .scanDurationMs)
        self.measuredSettleDelayMs = try container.decode(Int.self, forKey: .measuredSettleDelayMs)
        self.selectionRestored = try container.decode(Bool.self, forKey: .selectionRestored)
        self.truncatedBranches = try container.decode(Int.self, forKey: .truncatedBranches)
        self.probeTimeouts = try container.decode(Int.self, forKey: .probeTimeouts)
        self.cycleCount = try container.decode(Int.self, forKey: .cycleCount)
        self.nodeCount = try container.decode(Int.self, forKey: .nodeCount)
        self.leafCount = try container.decode(Int.self, forKey: .leafCount)
        self.folderCount = try container.decode(Int.self, forKey: .folderCount)
        self.candidatePatchCount = try container.decodeIfPresent(Int.self, forKey: .candidatePatchCount) ?? self.leafCount
        self.nonApplicablePatchCount = try container.decodeIfPresent(Int.self, forKey: .nonApplicablePatchCount) ?? 0
        self.root = try container.decode(LibraryNode.self, forKey: .root)
        self.categories = try container.decode([String].self, forKey: .categories)
        self.presetsByCategory = try container.decode([String: [String]].self, forKey: .presetsByCategory)
        self.skippedDirectoryCount = try container.decodeIfPresent(Int.self, forKey: .skippedDirectoryCount) ?? 0
        self.scanWarnings = try container.decodeIfPresent([String].self, forKey: .scanWarnings) ?? []
    }
}

enum LibraryAccessor {

    struct Inventory: Sendable, Codable {
        let categories: [String]
        let presetsByCategory: [String: [String]]
        let currentCategory: String?
        let currentPreset: String?
    }

    struct Runtime: Sendable {
        let ax: AXHelpers.Runtime
        let postMouseClick: @Sendable (CGPoint) -> Bool
        let postMouseDoubleClick: @Sendable (CGPoint) -> Bool

        static let production = Runtime(
            ax: .production,
            postMouseClick: { point in
                return LibraryAccessor.productionMouseClick(at: point)
            },
            postMouseDoubleClick: { point in
                _ = ProcessUtils.activateLogicPro()
                usleep(120_000)
                CGWarpMouseCursorPosition(point)
                usleep(30_000)
                if LibraryAccessor.postCliclick(command: "dc", at: point) {
                    return true
                }
                AXMouseHelper.doubleClick(at: point)
                return true
            }
        )
    }

    // MARK: - T4 scan orchestration (testable pure-function layer)

    public struct ScanResult: Sendable {
        public let root: LibraryRoot
        public let cachePath: String?
        public let selectionRestored: Bool
    }

    public enum ScanOrchestration {
        /// Pure orchestration around `enumerateTree`. Injectable for tests.
        /// Returns nil on panel closed / mutation abort / focus loss.
        /// If scan succeeds: writes JSON (tolerating failure → cachePath=nil),
        /// caches via onComplete, restores selection if cachedSelection present.
        public static func run(
            probe: TreeProbe,
            cachedSelection: (category: String, preset: String)?,
            restoreSelection: @Sendable @escaping (String, String) async -> Bool,
            writeJSON: @Sendable @escaping (LibraryRoot) async -> Bool,
            onComplete: @Sendable @escaping (LibraryRoot) async -> Void,
            settleDelayMs: Int
        ) async -> ScanResult? {
            guard var result = await LibraryAccessor.enumerateTree(
                maxDepth: 12, settleDelayMs: settleDelayMs, probe: probe
            ) else { return nil }

            // Tier-A: restore selection if we had a cached one
            var restored = false
            if let sel = cachedSelection {
                let ok = await restoreSelection(sel.category, sel.preset)
                restored = ok
            }

            // Stamp selectionRestored into a new LibraryRoot (since it's let)
            result = LibraryRoot(
                generatedAt: result.generatedAt,
                scanDurationMs: result.scanDurationMs,
                measuredSettleDelayMs: result.measuredSettleDelayMs,
                selectionRestored: restored,
                truncatedBranches: result.truncatedBranches,
                probeTimeouts: result.probeTimeouts,
                cycleCount: result.cycleCount,
                nodeCount: result.nodeCount,
                leafCount: result.leafCount,
                folderCount: result.folderCount,
                root: result.root,
                categories: result.categories,
                presetsByCategory: result.presetsByCategory,
                skippedDirectoryCount: result.skippedDirectoryCount,
                scanWarnings: result.scanWarnings
            )

            // Write JSON (tolerate failure)
            let wrote = await writeJSON(result)
            let cachePath = wrote ? "Resources/library-inventory.json" : nil

            // Cache in-memory
            await onComplete(result)

            return ScanResult(root: result, cachePath: cachePath, selectionRestored: restored)
        }
    }

    // MARK: - T3 path parsing + cache-backed resolution + click navigation

    public struct PathResolution: Sendable, Equatable {
        public let exists: Bool
        public let kind: LibraryNodeKind?
        public let matchedPath: String?
        public let children: [String]?
    }

    public struct PathRuntime: Sendable {
        public let clickByName: @Sendable (String) async -> Bool
        public let sleep: @Sendable (Int) async -> Void
        public init(
            clickByName: @Sendable @escaping (String) async -> Bool,
            sleep: @Sendable @escaping (Int) async -> Void
        ) {
            self.clickByName = clickByName
            self.sleep = sleep
        }
    }

    /// Parse a path string into its logical segments. Handles `\/` escape for
    /// literal slashes inside segment names. Returns nil for empty input or
    /// empty segments (E20).
    public static func parsePath(_ raw: String) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Strip trailing slash (but keep escaped trailing \/)
        var s = trimmed
        if s.hasSuffix("/") && !s.hasSuffix(#"\/"#) {
            s.removeLast()
        }
        if s.isEmpty { return nil }

        // Split on unescaped '/'. Replace '\/' with a sentinel, split, restore.
        let sentinel = "\u{FFFD}"
        let withSentinel = s.replacingOccurrences(of: #"\/"#, with: sentinel)
        let parts = withSentinel.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: sentinel, with: "/")
        }
        if parts.contains(where: { $0.isEmpty }) { return nil }
        return parts
    }

    /// Cache-backed path resolver. Traverses the already-scanned LibraryRoot;
    /// never touches live AX; returns existence + kind + children.
    public static func resolvePath(_ path: String, in root: LibraryRoot) -> PathResolution? {
        guard let segments = parsePath(path) else {
            return PathResolution(exists: false, kind: nil, matchedPath: nil, children: nil)
        }
        var current = root.root
        var matched: [String] = []
        for seg in segments {
            // Look for a child with name OR path-seg matching seg.
            // Path-seg is "Name" for unique siblings, "Name[i]" for disambiguated.
            guard let next = current.children.first(where: {
                $0.name == seg || $0.path.split(separator: "/").last.map(String.init) == seg
            }) else {
                return PathResolution(exists: false, kind: nil, matchedPath: nil, children: nil)
            }
            current = next
            matched.append(seg)
        }
        let children: [String]? = current.kind == .folder ? current.children.map(\.name) : nil
        return PathResolution(
            exists: true,
            kind: current.kind,
            matchedPath: matched.joined(separator: "/"),
            children: children
        )
    }

    /// Click through a path in the live Library (category → subfolder → preset).
    /// Each segment triggers a click and a settle delay. Returns false if any
    /// intermediate node is missing.
    @discardableResult
    public static func selectByPath(
        _ path: String, settleDelayMs: Int, runtime: PathRuntime
    ) async -> Bool {
        guard let segments = parsePath(path), !segments.isEmpty else { return false }
        for seg in segments {
            guard await runtime.clickByName(seg) else { return false }
            await runtime.sleep(settleDelayMs)
        }
        return true
    }

    // MARK: - T2 enumerateTree (recursive, probe-injectable)

    /// Recursive deep walker. Probes the AX tree (or injected mock) one path at
    /// a time, clicking folders to reveal children. Handles cycle detection,
    /// depth cap, probe timeout, duplicate-sibling disambiguation, and abort
    /// on external mutation / focus loss.
    ///
    /// Returns nil if the panel is closed (probe returns nil at root), focus
    /// is lost, or external mutation is detected mid-scan.
    public static func enumerateTree(
        maxDepth: Int = 12,
        settleDelayMs: Int = 500,
        probe: TreeProbe
    ) async -> LibraryRoot? {
        let start = Date()
        var visited = Set<Int>()
        var truncated = 0
        var probeTimeouts = 0
        var cycles = 0

        guard await probe.focusOK() else { return nil }

        // Read top-level
        let rootPath: [String] = []
        guard let topNames = await probe.childrenAt(rootPath) else {
            return nil   // panel closed / probe timeout at root
        }
        await probe.sleep(settleDelayMs)
        if await probe.mutationSinceLastCheck() { return nil }

        var topChildren: [LibraryNode] = []
        let filtered = topNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let disambiguated = disambiguate(filtered)
        for (name, displayPath) in disambiguated {
            guard await probe.focusOK() else { return nil }
            let path = [displayPath]
            let hash = probe.visitedHash(path)
            if visited.contains(hash) {
                cycles += 1
                topChildren.append(LibraryNode(name: name, path: displayPath, kind: .cycle, children: []))
                continue
            }
            visited.insert(hash)

            let node = await enumerateNode(
                name: name,
                pathComponents: path,
                currentDepth: 1,
                maxDepth: maxDepth,
                settleDelayMs: settleDelayMs,
                probe: probe,
                visited: &visited,
                truncated: &truncated,
                probeTimeouts: &probeTimeouts,
                cycles: &cycles
            )
            if node == nil { return nil } // mutation/focus abort propagated
            topChildren.append(node!)
        }

        let rootNode = LibraryNode(
            name: "(library-root)", path: "", kind: .folder, children: topChildren
        )
        let flat = flattenPresetsByCategory(rootNode)
        let counts = countNodes(rootNode)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        return LibraryRoot(
            generatedAt: ISO8601DateFormatter().string(from: start),
            scanDurationMs: durationMs,
            measuredSettleDelayMs: settleDelayMs,
            selectionRestored: false,
            truncatedBranches: truncated,
            probeTimeouts: probeTimeouts,
            cycleCount: cycles,
            nodeCount: counts.total,
            leafCount: counts.leaves,
            folderCount: counts.folders,
            root: rootNode,
            categories: filtered,
            presetsByCategory: flat
        )
    }

    private static func enumerateNode(
        name: String,
        pathComponents: [String],
        currentDepth: Int,
        maxDepth: Int,
        settleDelayMs: Int,
        probe: TreeProbe,
        visited: inout Set<Int>,
        truncated: inout Int,
        probeTimeouts: inout Int,
        cycles: inout Int
    ) async -> LibraryNode? {
        let pathStr = pathComponents.joined(separator: "/")

        if currentDepth > maxDepth {
            truncated += 1
            return LibraryNode(name: name, path: pathStr, kind: .truncated, children: [])
        }

        guard await probe.focusOK() else { return nil }

        // Click and read children
        guard let raw = await probe.childrenAt(pathComponents) else {
            probeTimeouts += 1
            return LibraryNode(name: name, path: pathStr, kind: .probeTimeout, children: [])
        }
        await probe.sleep(settleDelayMs)
        if await probe.mutationSinceLastCheck() { return nil }

        // Leaf: empty children array means this path has no descendants.
        if raw.isEmpty {
            return LibraryNode(name: name, path: pathStr, kind: .leaf, children: [])
        }

        let filtered = raw.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let siblings = disambiguate(filtered)
        var childNodes: [LibraryNode] = []
        for (childName, displayName) in siblings {
            let childPath = pathComponents + [displayName]
            let hash = probe.visitedHash(childPath)
            if visited.contains(hash) {
                cycles += 1
                childNodes.append(LibraryNode(
                    name: childName, path: childPath.joined(separator: "/"),
                    kind: .cycle, children: []
                ))
                continue
            }
            visited.insert(hash)

            let child = await enumerateNode(
                name: childName,
                pathComponents: childPath,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                settleDelayMs: settleDelayMs,
                probe: probe,
                visited: &visited,
                truncated: &truncated,
                probeTimeouts: &probeTimeouts,
                cycles: &cycles
            )
            if child == nil { return nil }
            childNodes.append(child!)
        }

        return LibraryNode(name: name, path: pathStr, kind: .folder, children: childNodes)
    }

    /// Disambiguate duplicate siblings with `[i]` suffix. Returns (raw name, display path-segment).
    /// Unique names keep their raw form; colliding names get `[0]`, `[1]`, etc. in order.
    private static func disambiguate(_ names: [String]) -> [(name: String, pathSeg: String)] {
        var counts: [String: Int] = [:]
        for n in names { counts[n, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var result: [(String, String)] = []
        for n in names {
            if (counts[n] ?? 0) > 1 {
                let i = seen[n, default: 0]
                seen[n] = i + 1
                result.append((n, "\(n)[\(i)]"))
            } else {
                result.append((n, n))
            }
        }
        return result
    }

    /// Flatten all leaf descendants under each top-level category into presetsByCategory.
    private static func flattenPresetsByCategory(_ root: LibraryNode) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for topCat in root.children {
            guard topCat.kind != .leaf else {
                out[topCat.name] = []; continue
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

    private static func countNodes(_ n: LibraryNode) -> (total: Int, leaves: Int, folders: Int) {
        var t = 1
        var l = n.kind == .leaf ? 1 : 0
        var f = n.kind == .folder ? 1 : 0
        for c in n.children {
            let r = countNodes(c)
            t += r.total
            l += r.leaves
            f += r.folders
        }
        return (t, l, f)
    }

    /// Enumerate the currently-visible Library: categories + presets of the
    /// currently-selected category. Returns nil if Library panel isn't found.
    static func enumerate(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Inventory? {
        guard let browser = findLibraryBrowser(runtime: runtime) else {
            return nil
        }
        // Collect all AXStaticText elements in the two AXList columns.
        let texts = AXHelpers.findAllDescendants(
            of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime.ax
        )
        // Separate into columns by X coordinate.
        // Column 1 (categories) is leftmost; Column 2 (presets) is to its right.
        var columnGroups: [(x: CGFloat, items: [(text: String, position: CGPoint)])] = []
        for t in texts {
            guard let value: String = AXHelpers.getAttribute(t, kAXValueAttribute, runtime: runtime.ax),
                  !value.isEmpty else { continue }
            guard let pos = position(of: t, runtime: runtime.ax) else { continue }
            // Group by x coordinate (snap to nearest 20px bucket)
            let bucket = CGFloat(Int(pos.x) / 20 * 20)
            if let idx = columnGroups.firstIndex(where: { abs($0.x - bucket) < 30 }) {
                columnGroups[idx].items.append((value, pos))
            } else {
                columnGroups.append((bucket, [(value, pos)]))
            }
        }
        // Sort columns left-to-right
        columnGroups.sort { $0.x < $1.x }
        guard columnGroups.count >= 2 else {
            return Inventory(
                categories: columnGroups.first?.items.map(\.text) ?? [],
                presetsByCategory: [:],
                currentCategory: nil,
                currentPreset: nil
            )
        }
        let categories = columnGroups[0].items.map(\.text)
        let presets    = columnGroups[1].items.map(\.text)

        // Try to find which category is currently highlighted (selected)
        let currentCategory = detectSelectedText(
            elements: columnGroups[0].items, browser: browser, runtime: runtime.ax
        )
        let currentPreset = readSelectedPresetName(in: browser, runtime: runtime.ax)
        // Presets belong to `currentCategory`
        var dict: [String: [String]] = [:]
        if let c = currentCategory {
            dict[c] = presets
        }
        return Inventory(
            categories: categories,
            presetsByCategory: dict,
            currentCategory: currentCategory,
            currentPreset: currentPreset
        )
    }

    /// Return presets visible in column 2 right now (the preset list for the
    /// currently-selected category in the Library browser).
    static func currentPresets(
        runtime: AXLogicProElements.Runtime = .production
    ) -> [String] {
        guard let browser = findLibraryBrowser(runtime: runtime) else { return [] }
        let texts = AXHelpers.findAllDescendants(
            of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime.ax
        )
        var columnGroups: [(x: CGFloat, items: [(text: String, position: CGPoint)])] = []
        for t in texts {
            guard let value: String = AXHelpers.getAttribute(t, kAXValueAttribute, runtime: runtime.ax),
                  !value.isEmpty else { continue }
            guard let pos = position(of: t, runtime: runtime.ax) else { continue }
            let bucket = CGFloat(Int(pos.x) / 20 * 20)
            if let idx = columnGroups.firstIndex(where: { abs($0.x - bucket) < 30 }) {
                columnGroups[idx].items.append((value, pos))
            } else {
                columnGroups.append((bucket, [(value, pos)]))
            }
        }
        columnGroups.sort { $0.x < $1.x }
        guard columnGroups.count >= 2 else { return [] }
        return columnGroups[1].items.map(\.text)
    }

    /// Full-inventory scan: clicks through every category and collects every
    /// preset visible in column 2 for each. Returns a complete category→presets
    /// map. Requires the Library panel to be open.
    static func enumerateAll(
        settleDelay: TimeInterval = 0.5,
        runtime: AXLogicProElements.Runtime = .production,
        library: Runtime = .production
    ) -> Inventory? {
        guard let first = enumerate(runtime: runtime) else { return nil }
        var all: [String: [String]] = [:]
        for category in first.categories {
            guard selectCategory(named: category, runtime: runtime, library: library) else { continue }
            Thread.sleep(forTimeInterval: settleDelay)
            all[category] = currentPresets(runtime: runtime)
        }
        return Inventory(
            categories: first.categories,
            presetsByCategory: all,
            currentCategory: first.currentCategory,
            currentPreset: first.currentPreset
        )
    }

    /// Select a category by name. Logic's Library can report successful AX
    /// selection without changing the visible column, so this also posts a
    /// native click at the row center when coordinates are readable.
    @discardableResult
    static func selectCategory(
        named name: String,
        runtime: AXLogicProElements.Runtime = .production,
        library: Runtime = .production
    ) -> Bool {
        guard let browser = findLibraryBrowser(runtime: runtime) else { return false }
        resetHorizontalScroll(for: browser, runtime: runtime.ax)
        let visibleFrame = frame(of: browser, runtime: runtime.ax)
        let texts = AXHelpers.findAllDescendants(
            of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime.ax
        )
        guard let targetEl = textElement(
            named: name,
            in: texts,
            prefer: .leftmost,
            visibleIn: visibleFrame,
            runtime: runtime.ax
        ) else { return false }
        let targetFrame = frame(of: targetEl, runtime: runtime.ax)
        let targetPoint = position(of: targetEl, runtime: runtime.ax)
        var selectedChildrenOK = false
        if let parent = AXHelpers.getAttribute(
            targetEl, kAXParentAttribute, runtime: runtime.ax
        ) as AXUIElement? {
            selectedChildrenOK = AXHelpers.setAttribute(
                parent,
                kAXSelectedChildrenAttribute,
                [targetEl] as CFArray,
                runtime: runtime.ax
            )
        }
        let pressOK = AXHelpers.performAction(targetEl, kAXPressAction, runtime: runtime.ax)
        let clicked: Bool
        if let pos = targetPoint {
            debugLibraryClick("selectCategory name=\(name) frame=\(String(describing: targetFrame)) point=\(pos)")
            clicked = library.postMouseClick(pos)
        } else {
            clicked = false
        }
        Thread.sleep(forTimeInterval: 0.30)
        return clicked || selectedChildrenOK || pressOK
    }

    @discardableResult
    private static func resetHorizontalScroll(for browser: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        let browserFrame = frame(of: browser, runtime: runtime)
        var didReset = false
        var root: AXUIElement? = browser
        for _ in 0..<5 {
            guard let current = root else { break }
            didReset = resetHorizontalScroll(
                in: current,
                browserFrame: browserFrame,
                runtime: runtime
            ) || didReset
            root = AXHelpers.getAttribute(
                current, kAXParentAttribute, runtime: runtime
            ) as AXUIElement?
        }
        if browserFrame == nil {
            debugLibraryClick("reset frame=nil")
        }
        return didReset
    }

    @discardableResult
    private static func resetHorizontalScroll(
        in browser: AXUIElement,
        browserFrame: CGRect?,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let scrollBars = AXHelpers.findAllDescendants(
            of: browser, role: kAXScrollBarRole, maxDepth: 10, runtime: runtime
        )
        var didReset = false
        for scrollBar in scrollBars {
            let orientation: String? = AXHelpers.getAttribute(
                scrollBar, kAXOrientationAttribute, runtime: runtime
            )
            guard orientation == kAXHorizontalOrientationValue as String else { continue }
            guard horizontallyOverlaps(scrollBar, browserFrame: browserFrame, runtime: runtime) else { continue }
            didReset = AXHelpers.setAttribute(
                scrollBar,
                kAXValueAttribute,
                NSNumber(value: 0),
                runtime: runtime
            ) || didReset
            if let scrollFrame = frame(of: scrollBar, runtime: runtime) {
                let resetPoint = CGPoint(x: scrollFrame.minX + 6, y: scrollFrame.midY)
                debugLibraryClick("reset scrollbar frame=\(scrollFrame) point=\(resetPoint)")
                _ = postCliclick(command: "c", at: resetPoint)
                didReset = true
            }
        }
        if didReset {
            Thread.sleep(forTimeInterval: 0.10)
        }
        return didReset
    }

    private static func horizontallyOverlaps(
        _ element: AXUIElement,
        browserFrame: CGRect?,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let browserFrame, let elementFrame = frame(of: element, runtime: runtime) else {
            return true
        }
        return elementFrame.maxX >= browserFrame.minX - 8
            && elementFrame.minX <= browserFrame.maxX + 8
    }

    /// Select a preset by name in the currently-active category. v3.0.3: Logic
    /// Pro 12's Library commits preset loading on **double-click**, not single
    /// click — a single click only highlights the row in the panel. Using
    /// `AXMouseHelper.doubleClick` (clickCount=2 on the second down/up pair)
    /// is what actually swaps the track's channel-strip instrument.
    @discardableResult
    static func selectPreset(
        named name: String,
        commit: Bool = true,
        runtime: AXLogicProElements.Runtime = .production,
        library: Runtime = .production
    ) -> Bool {
        guard let browser = findLibraryBrowser(runtime: runtime) else { return false }
        let visibleFrame = frame(of: browser, runtime: runtime.ax)
        let texts = AXHelpers.findAllDescendants(
            of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime.ax
        )
        guard let targetEl = textElement(
            named: name,
            in: texts,
            prefer: .rightmost,
            visibleIn: visibleFrame,
            runtime: runtime.ax
        ) ?? textElementByScrolling(
            named: name,
            in: browser,
            prefer: .rightmost,
            visibleIn: visibleFrame,
            runtime: runtime.ax
        ) else { return false }
        let targetFrame = frame(of: targetEl, runtime: runtime.ax)
        let targetPoint = position(of: targetEl, runtime: runtime.ax)
        if !commit, let pos = targetPoint {
            debugLibraryClick("selectPreset name=\(name) commit=\(commit) frame=\(String(describing: targetFrame)) point=\(pos)")
            let clicked = library.postMouseClick(pos)
            Thread.sleep(forTimeInterval: 0.30)
            if clicked { return true }
        }
        guard let parent = AXHelpers.getAttribute(
            targetEl, kAXParentAttribute, runtime: runtime.ax
        ) as AXUIElement? else {
            guard let pos = targetPoint else { return false }
            let clicked = commit ? library.postMouseDoubleClick(pos) : library.postMouseClick(pos)
            Thread.sleep(forTimeInterval: 0.2)
            return clicked
        }
        let arr = [targetEl] as CFArray
        let selectedChildrenOK = AXHelpers.setAttribute(parent, kAXSelectedChildrenAttribute, arr, runtime: runtime.ax)
        Thread.sleep(forTimeInterval: 0.20)   // let the scroll settle
        let pressResult = AXHelpers.performAction(targetEl, kAXPressAction, runtime: runtime.ax)
        Thread.sleep(forTimeInterval: 0.30)
        guard commit else {
            return selectedChildrenOK || pressResult
        }
        if let pos = targetPoint {
            debugLibraryClick("selectPreset name=\(name) commit=\(commit) frame=\(String(describing: targetFrame)) point=\(pos)")
            let doubleClicked = library.postMouseDoubleClick(pos)
            Thread.sleep(forTimeInterval: 0.50)
            return doubleClicked || selectedChildrenOK || pressResult
        }
        return selectedChildrenOK || pressResult
    }

    enum ColumnPreference {
        case leftmost
        case rightmost
    }

    private struct TextCandidate {
        let element: AXUIElement
        let value: String
        let columnX: CGFloat
        let y: CGFloat
    }

    /// Pick a Library row by visible column. Logic's Library can show duplicate
    /// names in multiple columns, such as top-level "Bass" and
    /// Synthesizer/Bass. Category clicks should target the left column; preset
    /// and folder clicks should target the right-most active column.
    private static func textElement(
        named name: String,
        in texts: [AXUIElement],
        prefer: ColumnPreference,
        visibleIn visibleFrame: CGRect? = nil,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let candidates = textCandidates(
            in: texts,
            visibleIn: visibleFrame,
            runtime: runtime
        )
        guard !candidates.isEmpty else { return nil }
        let columns = distinctColumnXs(from: candidates)
        debugLibraryClick(
            "textElement name=\(name) prefer=\(prefer) columns=\(columns) matches=\(candidates.filter { $0.value == name }.map { "\($0.value)@x=\($0.columnX),y=\($0.y)" })"
        )
        let preferredColumnX: CGFloat?
        switch prefer {
        case .leftmost:
            preferredColumnX = columns.first
        case .rightmost:
            guard columns.count >= 2 else { return nil }
            preferredColumnX = columns.last
        }
        guard let preferredColumnX else { return nil }
        let matches = candidates.filter {
            $0.value == name && abs($0.columnX - preferredColumnX) < 40
        }
        return matches.min { $0.y < $1.y }?.element
    }

    private static func textElementByScrolling(
        named name: String,
        in browser: AXUIElement,
        prefer: ColumnPreference,
        visibleIn visibleFrame: CGRect?,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        guard let scrollBar = verticalScrollBar(
            in: browser,
            prefer: prefer,
            browserFrame: visibleFrame,
            runtime: runtime
        ) else { return nil }

        for rawValue in stride(from: 0.0, through: 1.0001, by: 0.025) {
            _ = AXHelpers.setAttribute(
                scrollBar,
                kAXValueAttribute,
                NSNumber(value: min(1.0, rawValue)),
                runtime: runtime
            )
            Thread.sleep(forTimeInterval: 0.04)
            let texts = AXHelpers.findAllDescendants(
                of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime
            )
            if let target = textElement(
                named: name,
                in: texts,
                prefer: prefer,
                visibleIn: visibleFrame,
                runtime: runtime
            ) {
                return target
            }
        }
        return nil
    }

    private static func verticalScrollBar(
        in browser: AXUIElement,
        prefer: ColumnPreference,
        browserFrame: CGRect?,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let scrollBars = AXHelpers.findAllDescendants(
            of: browser, role: kAXScrollBarRole, maxDepth: 10, runtime: runtime
        )
        let vertical = scrollBars.filter { scrollBar in
            let orientation: String? = AXHelpers.getAttribute(
                scrollBar, kAXOrientationAttribute, runtime: runtime
            )
            guard orientation == kAXVerticalOrientationValue as String else { return false }
            return horizontallyOverlaps(scrollBar, browserFrame: browserFrame, runtime: runtime)
        }
        let sorted = vertical.sorted { lhs, rhs in
            let lhsX = frame(of: lhs, runtime: runtime)?.midX ?? 0
            let rhsX = frame(of: rhs, runtime: runtime)?.midX ?? 0
            return lhsX < rhsX
        }
        switch prefer {
        case .leftmost:
            return sorted.first
        case .rightmost:
            return sorted.last
        }
    }

    private static func distinctColumnXs(from candidates: [TextCandidate]) -> [CGFloat] {
        candidates.map(\.columnX).sorted().reduce(into: []) { columns, x in
            if let last = columns.last, abs(last - x) < 40 {
                return
            }
            columns.append(x)
        }
    }

    private static func textCandidates(
        in texts: [AXUIElement],
        visibleIn visibleFrame: CGRect?,
        runtime: AXHelpers.Runtime
    ) -> [TextCandidate] {
        texts.compactMap { t -> TextCandidate? in
            guard let rawValue: String = AXHelpers.getAttribute(t, kAXValueAttribute, runtime: runtime),
                  ancestorRole(t, role: kAXListRole as String, maxDepth: 4, runtime: runtime) != nil
            else { return nil }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let elementFrame = frame(of: t, runtime: runtime)
            if let visibleFrame, let elementFrame, !visibleFrame.intersects(elementFrame) {
                return nil
            }
            let elementPosition = position(of: t, runtime: runtime)
            return TextCandidate(
                element: t,
                value: value,
                columnX: elementFrame?.midX ?? elementPosition?.x ?? 0,
                y: elementFrame?.minY ?? elementPosition?.y ?? 0
            )
        }
    }

    private static func ancestorRole(
        _ element: AXUIElement,
        role: String,
        maxDepth: Int,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<maxDepth {
            guard let parent = AXHelpers.getAttribute(
                current ?? element,
                kAXParentAttribute,
                runtime: runtime
            ) as AXUIElement? else {
                return nil
            }
            if (AXHelpers.getAttribute(parent, kAXRoleAttribute, runtime: runtime) as String?) == role {
                return parent
            }
            current = parent
        }
        return nil
    }

    /// Convenience: set category then preset with a short delay for Logic to
    /// update the second column.
    @discardableResult
    static func setInstrument(
        category: String,
        preset: String,
        settleDelay: TimeInterval = 0.6,
        runtime: AXLogicProElements.Runtime = .production,
        library: Runtime = .production
    ) -> Bool {
        guard selectCategory(named: category, runtime: runtime, library: library) else {
            return false
        }
        Thread.sleep(forTimeInterval: settleDelay)
        return selectPreset(named: preset, runtime: runtime, library: library)
    }

    /// v3.0.4 — N-segment live navigation through the 2-column sliding Library
    /// Panel. Logic's Library is a "finder column" view: clicking a subfolder
    /// in column 2 slides the view (column 1 becomes the subfolder, column 2
    /// shows its direct children). Clicking a leaf preset loads it without
    /// sliding. The actual AX primitive is identical for every segment — find
    /// the AXStaticText by name in the currently-visible browser, set the
    /// parent AXList's `AXSelectedChildren`, fire AXPress. Logic handles the
    /// slide automatically.
    ///
    /// Returns true if every segment's click dispatched successfully. Returns
    /// false on the first segment whose name isn't found in the currently-
    /// visible Library browser.
    @discardableResult
    static func selectPath(
        segments: [String],
        settleDelay: TimeInterval = 1.0,
        runtime: AXLogicProElements.Runtime = .production,
        library: Runtime = .production
    ) -> Bool {
        guard !segments.isEmpty else { return false }
        for (idx, seg) in segments.enumerated() {
            // First segment: may require selectCategory semantics if the panel
            // is currently showing a subcategory view rather than top level.
            // In practice `selectCategory` and `selectPreset` do the same
            // AXSelectedChildren+AXPress thing on whatever is currently
            // visible, so either works for "click this name in the current
            // browser". We deliberately use `selectPreset` for all but the
            // first segment because `selectPreset`'s coord-click fallback
            // (when the parent AXList isn't reachable) is what actually
            // handles edge cases in deep viewports.
            let ok: Bool
            if idx == 0 {
                ok = selectCategory(named: seg, runtime: runtime, library: library)
            } else {
                ok = selectPreset(
                    named: seg,
                    commit: idx == segments.count - 1,
                    runtime: runtime,
                    library: library
                )
            }
            if !ok { return false }
            // Allow Logic to slide the column / update visible children before
            // the next segment's name lookup runs.
            //
            // #135 — a FIXED 0.35s settle is too short on a cold Library panel:
            // Logic's finder-column slide can exceed 350ms, so the next
            // segment's AXStaticText is not yet realized in the AX tree and the
            // lookup spuriously returns not-found (surfaced as the misleading
            // "Library path not fully resolvable"). Poll for the next segment's
            // row to appear, bounded by `settleDelay` total, instead of a single
            // blind sleep. Falls back to the full sleep if the row never shows
            // (the next segment's own selectCategory/selectPreset then fails
            // honestly, preserving the State C contract).
            if idx < segments.count - 1 {
                let nextSeg = segments[idx + 1]
                waitForSegmentVisible(
                    named: nextSeg,
                    timeout: settleDelay,
                    rightmostColumnOnly: true,
                    runtime: runtime
                )
            }
        }
        return true
    }

    /// #135 — bounded poll for a Library row (AXStaticText) with `name` to be
    /// realized in the currently-visible browser, after a column slide. Polls in
    /// short steps up to `timeout` total. Returns as soon as the row appears, or
    /// after `timeout` elapses (the caller's next segment lookup then fails
    /// honestly if it never appeared — no false success is introduced here).
    static func waitForSegmentVisible(
        named name: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        rightmostColumnOnly: Bool = false,
        runtime: AXLogicProElements.Runtime = .production
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if segmentIsVisible(
                named: name,
                rightmostColumnOnly: rightmostColumnOnly,
                runtime: runtime
            ) { return }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
    }

    /// Read-only check: is an AXStaticText whose value equals `name` present in
    /// the currently-visible Library browser? Used by `waitForSegmentVisible`.
    static func segmentIsVisible(
        named name: String,
        rightmostColumnOnly: Bool = false,
        runtime: AXLogicProElements.Runtime = .production
    ) -> Bool {
        guard let browser = findLibraryBrowser(runtime: runtime) else { return false }
        let visibleFrame = frame(of: browser, runtime: runtime.ax)
        let texts = AXHelpers.findAllDescendants(
            of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime.ax
        )
        if rightmostColumnOnly {
            return textElement(
                named: name,
                in: texts,
                prefer: .rightmost,
                visibleIn: visibleFrame,
                runtime: runtime.ax
            ) != nil
        }
        return textCandidates(
            in: texts,
            visibleIn: visibleFrame,
            runtime: runtime.ax
        ).contains { $0.value == name }
    }

    // MARK: - Private helpers

    /// Fast precondition check for callers that want to avoid starting a full
    /// scan when the Library panel isn't open. Read-only AX query, typically
    /// completes in < 100 ms. Requires a browser whose description explicitly
    /// matches "Library" (ko / en) — falling back to any browser is too loose
    /// because Logic Pro may expose Inspector or File browsers with different roles.
    public static func isLibraryPanelOpen(
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { return false }
        let browsers = AXHelpers.findAllDescendants(
            of: window, role: kAXBrowserRole, maxDepth: 10, runtime: runtime.ax
        )
        for b in browsers {
            let desc = AXHelpers.getDescription(b, runtime: runtime.ax) ?? ""
            if desc == "라이브러리" || desc.lowercased() == "library" {
                return true
            }
        }
        return false
    }

    private static func findLibraryBrowser(
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { return nil }
        let browsers = AXHelpers.findAllDescendants(
            of: window, role: kAXBrowserRole, maxDepth: 10, runtime: runtime.ax
        )
        for b in browsers {
            let desc = AXHelpers.getDescription(b, runtime: runtime.ax) ?? ""
            if desc == "라이브러리" || desc.lowercased() == "library" {
                return b
            }
        }
        // Fallback: return first browser in the window (Library is typically the
        // most prominent one)
        return browsers.first
    }

    private static func position(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> CGPoint? {
        // H2 (P2-5): fail-closed on non-AXValue OR wrong-subtype AXValue (the
        // previous code checked CFGetTypeID but ignored AXValueGetValue's Bool,
        // so a wrong-subtype value silently produced a (0,0) center).
        guard let cgPos = AXHelpers.getPosition(element, runtime: runtime),
              let cgSize = AXHelpers.getSize(element, runtime: runtime) else {
            return nil
        }
        return CGPoint(x: cgPos.x + cgSize.width / 2, y: cgPos.y + cgSize.height / 2)
    }

    private static func frame(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> CGRect? {
        guard let cgPos = AXHelpers.getPosition(element, runtime: runtime),
              let cgSize = AXHelpers.getSize(element, runtime: runtime) else {
            return nil
        }
        return CGRect(origin: cgPos, size: cgSize)
    }

    /// Try to detect which item in a column is currently selected/highlighted.
    ///
    /// v3.1.0 (T2) — `selectPreset` commits selection by setting
    /// `AXSelectedChildren` on the parent AXList, so we can read it back
    /// from any AXList descendant of the browser and extract the contained
    /// AXStaticText's value. Returns nil when no AXList exposes a readable
    /// `AXSelectedChildren` — Honest Contract callers treat nil as
    /// `readback_unavailable`.
    ///
    /// v3.1.0 (Ralph-2 / P1-2) — now honours the `elements` column bucket.
    /// Previously this delegate ignored its input and returned the "last"
    /// selected text found during a full browser walk, which deterministically
    /// collapsed to the preset column value for BOTH the category and preset
    /// call sites in `enumerate()`. The result was that `Inventory.currentCategory`
    /// silently held the preset name, poisoning `presetsByCategory` dict keys
    /// and misreporting the current category via `logic://library/inventory`.
    /// We now compute the column's x-range from the passed items and only
    /// accept selected children whose AXPosition.x falls inside that range.
    private static func detectSelectedText(
        elements: [(text: String, position: CGPoint)],
        browser: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        // Empty column → no selection can belong to it.
        guard !elements.isEmpty else { return nil }
        let xs = elements.map(\.position.x)
        // Use the bucket that `enumerate()` already snapped to (20px grid,
        // 30px neighbourhood). Extend a half-bucket each side so a selected
        // child sitting mid-column is included.
        let minX = (xs.min() ?? 0) - 10
        let maxX = (xs.max() ?? 0) + 10
        return readSelectedTextInColumn(
            in: browser, columnMinX: minX, columnMaxX: maxX, runtime: runtime
        )
    }

    /// Walk every AXList descendant's `AXSelectedChildren`, return the value
    /// of the first selected child whose `AXPosition.x` falls inside
    /// `[columnMinX, columnMaxX]`. Returns nil when no selection in that
    /// column is readable (contract's `readback_unavailable` signal).
    static func readSelectedTextInColumn(
        in browser: AXUIElement,
        columnMinX: CGFloat,
        columnMaxX: CGFloat,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let lists = AXHelpers.findAllDescendants(
            of: browser, role: kAXListRole, maxDepth: 6, runtime: runtime
        )
        for list in lists {
            guard let arr: [AXUIElement] = AXHelpers.getAttribute(
                list,
                kAXSelectedChildrenAttribute,
                runtime: runtime
            ), !arr.isEmpty else {
                continue
            }
            for child in arr {
                guard let value: String = AXHelpers.getAttribute(
                    child, kAXValueAttribute, runtime: runtime
                ), !value.isEmpty else { continue }
                guard let pos = position(of: child, runtime: runtime) else { continue }
                if pos.x >= columnMinX && pos.x <= columnMaxX {
                    return value
                }
            }
        }
        return nil
    }

    /// Read the currently-selected preset name from the Library browser by
    /// walking every AXList descendant, asking for its `AXSelectedChildren`,
    /// and pulling the AXValue off the first selected child. Returns nil when
    /// nothing exposes a readable selection attribute (which is the contract's
    /// `readback_unavailable` signal).
    ///
    /// v3.1.0 (Ralph-2 / P1-2) — the implementation still walks the whole
    /// browser (no column filter — this is the deliberately column-agnostic
    /// variant used by `readBackLibraryPreset`/`track.set_instrument`, which
    /// only cares about the deepest/last selected column, i.e. the preset).
    static func readSelectedPresetName(
        in browser: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let lists = AXHelpers.findAllDescendants(
            of: browser, role: kAXListRole, maxDepth: 6, runtime: runtime
        )
        var lastText: String? = nil
        var lastX: CGFloat = -CGFloat.greatestFiniteMagnitude
        for list in lists {
            guard let arr: [AXUIElement] = AXHelpers.getAttribute(
                list,
                kAXSelectedChildrenAttribute,
                runtime: runtime
            ), !arr.isEmpty else {
                continue
            }
            for child in arr {
                if let rawValue: String = AXHelpers.getAttribute(
                    child, kAXValueAttribute, runtime: runtime
                ) {
                    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    // Library has 2 columns (category, preset); the preset
                    // column comes after the category column left-to-right.
                    // Prefer the rightmost selected child so the return value
                    // lands on the preset whenever both columns have a
                    // selection active. Falls back to last-seen if positions
                    // are not readable.
                    if let pos = position(of: child, runtime: runtime) {
                        if pos.x >= lastX {
                            lastX = pos.x
                            lastText = value
                        }
                    } else if lastText == nil {
                        lastText = value
                    }
                }
            }
        }
        return lastText
    }

    /// Inject a single left-button mouse click at the given screen point.
    /// Uses CGEvent — macOS accepts this from processes with Accessibility
    /// permission.
    static func productionMouseClick(at point: CGPoint) -> Bool {
        _ = ProcessUtils.activateLogicPro()
        usleep(120_000)
        CGWarpMouseCursorPosition(point)
        usleep(30_000)
        if postCliclick(command: "c", at: point) {
            return true
        }
        return AXMouseHelper.click(at: point)
    }

    private static func postCliclick(command: String, at point: CGPoint) -> Bool {
        let candidates = ["/opt/homebrew/bin/cliclick", "/usr/local/bin/cliclick"]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            return false
        }
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        debugLibraryClick("cliclick \(command):\(x),\(y) executable=\(executable)")
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: executable,
            arguments: ["\(command):\(x),\(y)"],
            timeout: 1.0,
            outputLimitBytes: 4_096
        ) else {
            debugLibraryClick("cliclick \(command):\(x),\(y) result=spawn_or_timeout")
            return false
        }
        debugLibraryClick("cliclick \(command):\(x),\(y) exit=\(output.exitCode)")
        return output.exitCode == 0
    }

    private static func debugLibraryClick(_ message: String) {
        guard ProcessInfo.processInfo.environment["LOGIC_LIBRARY_CLICK_DEBUG"] == "1" else {
            return
        }
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/logic-library-click-debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: Data(line.utf8))
    }
}
