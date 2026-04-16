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
/// Real production: wraps live AX reads + CGEvent clicks (in T4's channel code).
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
    public let root: LibraryNode
    public let categories: [String]
    public let presetsByCategory: [String: [String]]

    public init(
        generatedAt: String, scanDurationMs: Int, measuredSettleDelayMs: Int,
        selectionRestored: Bool,
        truncatedBranches: Int, probeTimeouts: Int, cycleCount: Int,
        nodeCount: Int, leafCount: Int, folderCount: Int,
        root: LibraryNode, categories: [String], presetsByCategory: [String: [String]]
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
        self.root = root
        self.categories = categories
        self.presetsByCategory = presetsByCategory
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

        static let production = Runtime(
            ax: .production,
            postMouseClick: { point in
                return LibraryAccessor.productionMouseClick(at: point)
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
                presetsByCategory: result.presetsByCategory
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
        // First column is categories; second is presets
        let categories = columnGroups[0].items.map(\.text)
        let presets    = columnGroups[1].items.map(\.text)

        // Try to find which category is currently highlighted (selected)
        let currentCategory = detectSelectedText(
            elements: columnGroups[0].items, browser: browser, runtime: runtime.ax
        )
        let currentPreset = detectSelectedText(
            elements: columnGroups[1].items, browser: browser, runtime: runtime.ax
        )
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

    /// Select a category by name. Injects a real mouse click at the
    /// category's screen position. Returns true if the element was found
    /// and the click was dispatched.
    @discardableResult
    static func selectCategory(
        named name: String,
        runtime: AXLogicProElements.Runtime = .production,
        library: Runtime = .production
    ) -> Bool {
        guard let browser = findLibraryBrowser(runtime: runtime) else { return false }
        let texts = AXHelpers.findAllDescendants(
            of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime.ax
        )
        // Find the category in the leftmost column
        let targets = texts.compactMap { t -> (text: String, pos: CGPoint)? in
            guard let value: String = AXHelpers.getAttribute(t, kAXValueAttribute, runtime: runtime.ax),
                  let pos = position(of: t, runtime: runtime.ax) else { return nil }
            return (value, pos)
        }
        // Lookup exact match
        guard let target = targets.first(where: { $0.text == name }) else {
            return false
        }
        return library.postMouseClick(target.pos)
    }

    /// Select a preset by name in the currently-active category. Injects a
    /// real mouse click at the preset's screen position. Triggers Logic Pro
    /// to load that instrument on the focused track.
    @discardableResult
    static func selectPreset(
        named name: String,
        runtime: AXLogicProElements.Runtime = .production,
        library: Runtime = .production
    ) -> Bool {
        guard let browser = findLibraryBrowser(runtime: runtime) else { return false }
        let texts = AXHelpers.findAllDescendants(
            of: browser, role: kAXStaticTextRole, maxDepth: 6, runtime: runtime.ax
        )
        let matches = texts.compactMap { t -> (text: String, pos: CGPoint)? in
            guard let value: String = AXHelpers.getAttribute(t, kAXValueAttribute, runtime: runtime.ax),
                  let pos = position(of: t, runtime: runtime.ax) else { return nil }
            return (value, pos)
        }
        guard let target = matches.first(where: { $0.text == name }) else { return false }
        return library.postMouseClick(target.pos)
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
        var positionValue: AnyObject?
        let positionResult = AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionValue
        )
        var sizeValue: AnyObject?
        let sizeResult = AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeValue
        )
        guard positionResult == .success, sizeResult == .success,
              let posRaw = positionValue, let sizeRaw = sizeValue else {
            return nil
        }
        // E19: guard against non-AXValue returns instead of force-unwrapping
        guard CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return nil
        }
        var cgPos = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue((posRaw as! AXValue), .cgPoint, &cgPos)
        AXValueGetValue((sizeRaw as! AXValue), .cgSize, &cgSize)
        return CGPoint(x: cgPos.x + cgSize.width / 2, y: cgPos.y + cgSize.height / 2)
    }

    /// Try to detect which item in a column is currently selected/highlighted.
    /// Logic Pro's Library uses visual highlighting that is not exposed via
    /// standard AX attributes on AXStaticText; as a fallback we return nil.
    private static func detectSelectedText(
        elements: [(text: String, position: CGPoint)],
        browser: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        // Logic Pro does not expose selection on AXStaticText. Return nil so
        // callers know the info isn't available.
        return nil
    }

    /// Inject a single left-button mouse click at the given screen point.
    /// Uses CGEvent — macOS accepts this from processes with Accessibility
    /// permission.
    static func productionMouseClick(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        down?.post(tap: .cghidEventTap)
        // Brief delay between down and up so macOS treats this as a single click
        usleep(50_000) // 50ms
        up?.post(tap: .cghidEventTap)
        return down != nil && up != nil
    }
}
