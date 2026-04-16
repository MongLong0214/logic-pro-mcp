import ApplicationServices
import CoreGraphics
import Foundation

/// Logic Pro plugin-window Setting-menu inspector.
///
/// Walks the `AXMenuButton → AXMenu → AXMenuItem` tree exposed by Logic Pro's
/// plugin-window header bar. Methods are closure-injected via `PluginPresetProbe`
/// and `PluginWindowRuntime` for deterministic testing without a live Logic Pro.
///
/// Interaction mechanism (AXPress vs CGEvent) is T0-gated; see
/// `docs/spikes/F2-T0-plugin-menu-probe-result.md` for the empirical verdict.

// MARK: - T1 types (PRD §4.2)

public enum PluginPresetNodeKind: String, Codable, Sendable, Equatable {
    case folder, leaf, separator, action
    case truncated, probeTimeout, cycle
}

public struct PluginPresetNode: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let kind: PluginPresetNodeKind
    public let children: [PluginPresetNode]

    public init(name: String, path: String, kind: PluginPresetNodeKind, children: [PluginPresetNode]) {
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
    }
}

public struct PluginPresetCache: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let pluginName: String
    public let pluginIdentifier: String
    public let pluginVersion: String?
    public let contentHash: String
    public let generatedAt: String
    public let scanDurationMs: Int
    public let measuredSubmenuOpenDelayMs: Int
    public let truncatedBranches: Int
    public let probeTimeouts: Int
    public let cycleCount: Int
    public let nodeCount: Int
    public let leafCount: Int
    public let folderCount: Int
    public let root: PluginPresetNode

    public init(
        schemaVersion: Int = 1,
        pluginName: String,
        pluginIdentifier: String,
        pluginVersion: String?,
        contentHash: String,
        generatedAt: String,
        scanDurationMs: Int,
        measuredSubmenuOpenDelayMs: Int,
        truncatedBranches: Int,
        probeTimeouts: Int,
        cycleCount: Int,
        nodeCount: Int,
        leafCount: Int,
        folderCount: Int,
        root: PluginPresetNode
    ) {
        self.schemaVersion = schemaVersion
        self.pluginName = pluginName
        self.pluginIdentifier = pluginIdentifier
        self.pluginVersion = pluginVersion
        self.contentHash = contentHash
        self.generatedAt = generatedAt
        self.scanDurationMs = scanDurationMs
        self.measuredSubmenuOpenDelayMs = measuredSubmenuOpenDelayMs
        self.truncatedBranches = truncatedBranches
        self.probeTimeouts = probeTimeouts
        self.cycleCount = cycleCount
        self.nodeCount = nodeCount
        self.leafCount = leafCount
        self.folderCount = folderCount
        self.root = root
    }
}

public struct PluginPresetInventory: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let plugins: [String: PluginPresetCache]

    public init(schemaVersion: Int = 1, generatedAt: String, plugins: [String: PluginPresetCache]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.plugins = plugins
    }
}

public struct MenuHop: Sendable, Equatable {
    public let indexInParent: Int
    public let name: String

    public init(indexInParent: Int, name: String) {
        self.indexInParent = indexInParent
        self.name = name
    }
}

public struct PluginMenuItemInfo: Sendable, Equatable {
    public let name: String
    public let kind: PluginPresetNodeKind
    public let hasSubmenu: Bool

    public init(name: String, kind: PluginPresetNodeKind, hasSubmenu: Bool) {
        self.name = name
        self.kind = kind
        self.hasSubmenu = hasSubmenu
    }
}

/// AXUIElement Sendable wrapper — NEW type introduced by F2 (no F1 predecessor).
/// `@unchecked Sendable` is safe because the element is only dereferenced on
/// the `AccessibilityChannel` actor.
public final class AXUIElementSendable: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}

public struct ScannerWindowRecord: Sendable {
    public let cgWindowID: CGWindowID
    public let bundleID: String
    public let windowTitle: String
    public let element: AXUIElementSendable

    public init(cgWindowID: CGWindowID, bundleID: String, windowTitle: String, element: AXUIElementSendable) {
        self.cgWindowID = cgWindowID
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.element = element
    }
}

public struct PluginPresetProbe: Sendable {
    public let menuItemsAt: @Sendable ([String]) async -> [PluginMenuItemInfo]?
    public let pressMenuItem: @Sendable ([String]) async -> Bool
    public let focusOK: @Sendable () async -> Bool
    public let mutationSinceLastCheck: @Sendable () async -> Bool
    public let sleep: @Sendable (Int) async -> Void
    public let visitedHash: @Sendable ([String]) -> Int

    public init(
        menuItemsAt: @Sendable @escaping ([String]) async -> [PluginMenuItemInfo]?,
        pressMenuItem: @Sendable @escaping ([String]) async -> Bool,
        focusOK: @Sendable @escaping () async -> Bool,
        mutationSinceLastCheck: @Sendable @escaping () async -> Bool,
        sleep: @Sendable @escaping (Int) async -> Void,
        visitedHash: @Sendable @escaping ([String]) -> Int
    ) {
        self.menuItemsAt = menuItemsAt
        self.pressMenuItem = pressMenuItem
        self.focusOK = focusOK
        self.mutationSinceLastCheck = mutationSinceLastCheck
        self.sleep = sleep
        self.visitedHash = visitedHash
    }
}

public struct PluginWindowRuntime: Sendable {
    public let findWindow: @Sendable (Int) async -> AXUIElementSendable?
    public let openWindow: @Sendable (Int) async throws -> AXUIElementSendable
    public let closeWindow: @Sendable (AXUIElementSendable) async -> Bool
    public let listOpenWindows: @Sendable () async -> [AXUIElementSendable]
    public let identifyPlugin: @Sendable (AXUIElementSendable) async -> (name: String, bundleID: String, version: String?)?
    public let nowMs: @Sendable () -> Int

    public init(
        findWindow: @Sendable @escaping (Int) async -> AXUIElementSendable?,
        openWindow: @Sendable @escaping (Int) async throws -> AXUIElementSendable,
        closeWindow: @Sendable @escaping (AXUIElementSendable) async -> Bool,
        listOpenWindows: @Sendable @escaping () async -> [AXUIElementSendable],
        identifyPlugin: @Sendable @escaping (AXUIElementSendable) async -> (name: String, bundleID: String, version: String?)?,
        nowMs: @Sendable @escaping () -> Int
    ) {
        self.findWindow = findWindow
        self.openWindow = openWindow
        self.closeWindow = closeWindow
        self.listOpenWindows = listOpenWindows
        self.identifyPlugin = identifyPlugin
        self.nowMs = nowMs
    }
}

// MARK: - Errors

public enum PluginError: Error, Equatable {
    case menuMutated
    case focusLost
    case invalidPath(reason: String)
    case pressFailedAt(path: [String])
    case openTimeout(trackIndex: Int)
}

// MARK: - Constants

public let maxPluginMenuDepth = 10

// MARK: - T2: enumerateMenuTree

public enum PluginInspector {
    /// Recursive walker producing a `PluginPresetNode` tree from a `PluginPresetProbe`.
    ///
    /// - Parameters:
    ///   - probe: Injected probe abstraction (tests supply scripted closures).
    ///   - maxDepth: Hard cap for recursion (default 10; branches deeper than this emit `kind: .truncated`).
    ///   - settleMs: Sleep between consecutive submenu opens (default 300 ms).
    /// - Throws: `PluginError.menuMutated` if `probe.mutationSinceLastCheck` reports external mutation;
    ///           `PluginError.focusLost` if `probe.focusOK` reports false.
    public static func enumerateMenuTree(
        probe: PluginPresetProbe,
        maxDepth: Int = maxPluginMenuDepth,
        settleMs: Int = 300
    ) async throws -> (root: PluginPresetNode, cycleCount: Int) {
        var visited = Set<Int>()
        var cycleCount = 0
        let rootNode = try await walk(
            pathSegs: [],
            displayName: "(root)",
            depth: 0,
            maxDepth: maxDepth,
            settleMs: settleMs,
            probe: probe,
            visited: &visited,
            cycleCount: &cycleCount
        )
        return (rootNode, cycleCount)
    }

    private static func walk(
        pathSegs: [String],
        displayName: String,
        depth: Int,
        maxDepth: Int,
        settleMs: Int,
        probe: PluginPresetProbe,
        visited: inout Set<Int>,
        cycleCount: inout Int
    ) async throws -> PluginPresetNode {
        if depth > maxDepth {
            return PluginPresetNode(
                name: displayName,
                path: pathSegs.joined(separator: "/"),
                kind: .truncated,
                children: []
            )
        }

        if await probe.mutationSinceLastCheck() { throw PluginError.menuMutated }
        if await !probe.focusOK() { throw PluginError.focusLost }

        let hash = probe.visitedHash(pathSegs)
        if visited.contains(hash) {
            cycleCount += 1
            return PluginPresetNode(
                name: displayName,
                path: pathSegs.joined(separator: "/"),
                kind: .cycle,
                children: []
            )
        }
        visited.insert(hash)

        guard let items = await probe.menuItemsAt(pathSegs) else {
            return PluginPresetNode(
                name: displayName,
                path: pathSegs.joined(separator: "/"),
                kind: .probeTimeout,
                children: []
            )
        }

        // Disambiguate duplicate names with [i] suffix
        var nameCounts: [String: Int] = [:]
        var children: [PluginPresetNode] = []

        for item in items {
            let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue } // AC-3 whitespace skip

            let baseName = item.name
            let sameNameCount = items.filter { $0.name == baseName }.count
            let suffixedName: String
            if sameNameCount > 1 {
                let idx = nameCounts[baseName, default: 0]
                suffixedName = "\(baseName)[\(idx)]"
                nameCounts[baseName] = idx + 1
            } else {
                suffixedName = baseName
            }

            let childSegs = pathSegs + [suffixedName]
            let childPath = childSegs.joined(separator: "/")

            if item.hasSubmenu && item.kind == .folder {
                await probe.sleep(settleMs)
                let subNode = try await walk(
                    pathSegs: childSegs,
                    displayName: suffixedName,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    settleMs: settleMs,
                    probe: probe,
                    visited: &visited,
                    cycleCount: &cycleCount
                )
                children.append(subNode)
            } else {
                children.append(PluginPresetNode(
                    name: suffixedName,
                    path: childPath,
                    kind: item.kind,
                    children: []
                ))
            }
        }

        return PluginPresetNode(
            name: displayName,
            path: pathSegs.joined(separator: "/"),
            kind: .folder,
            children: children
        )
    }

    // MARK: - T3: path parse + resolve + select

    /// Parse a path string into ordered segments.
    /// Escape rules: `\/` → `/` in segment names; `\\` → `\` in segment names.
    /// State-machine parse — two-character markers for escape, split only on UNESCAPED `/`.
    public static func parsePath(_ raw: String) throws -> [String] {
        var s = raw
        // Strip trailing `/` only when it is NOT an escaped `\/` (last segment ending with literal "/")
        if s.hasSuffix("/") && !s.hasSuffix(#"\/"#) { s.removeLast() }
        if s.isEmpty { return [] }

        // Unique markers outside Unicode BMP range won't collide with preset text
        let bsMarker = "\u{E001}"   // stands for literal \
        let slMarker = "\u{E002}"   // stands for literal /
        // Order: \\ first (two backslashes) → bsMarker, then \/ → slMarker
        s = s.replacingOccurrences(of: #"\\"#, with: bsMarker)
        s = s.replacingOccurrences(of: #"\/"#, with: slMarker)

        let rawSegs = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for seg in rawSegs where seg.isEmpty {
            throw PluginError.invalidPath(reason: "empty segment")
        }
        let segs = rawSegs.map { seg -> String in
            var u = seg
            u = u.replacingOccurrences(of: slMarker, with: "/")
            u = u.replacingOccurrences(of: bsMarker, with: #"\"#)
            return u
        }
        return segs
    }

    /// Encode segments back to a single path string.
    /// Encode order (mirror of parsePath): `\` → `\\`, then `/` → `\/`.
    public static func encodePath(_ segs: [String]) -> String {
        segs.map { seg -> String in
            let escaped = seg.replacingOccurrences(of: #"\"#, with: #"\\"#)
            return escaped.replacingOccurrences(of: "/", with: #"\/"#)
        }.joined(separator: "/")
    }

    /// Resolve a path string to a sequence of `MenuHop` into the given tree.
    /// Returns nil if any segment doesn't match a child.
    /// Matching strategy:
    ///   1. Exact `child.name == seg` match (covers pre-disambiguated trees like "Pad[1]" stored verbatim)
    ///   2. Disambig fallback: if `seg` has `[i]` suffix AND no exact match, find i-th sibling whose raw name equals seg's base (covers callers supplying `Pad[1]` against raw-named tree with two `Pad` siblings)
    public static func resolveMenuPath(_ raw: String, in root: PluginPresetNode) throws -> [MenuHop]? {
        let segs = try parsePath(raw)
        if segs.isEmpty { return nil }

        var current = root
        var hops: [MenuHop] = []
        for seg in segs {
            // Exact-match first
            if let exactIdx = current.children.firstIndex(where: { $0.name == seg }) {
                hops.append(MenuHop(indexInParent: exactIdx, name: seg))
                current = current.children[exactIdx]
                continue
            }
            // Fallback: parse disambig suffix against raw-name siblings
            let (baseName, dupIdx) = parseDisambigSuffix(seg)
            guard let dupIdx = dupIdx, dupIdx >= 0 else { return nil }
            let sameBase = current.children.enumerated().compactMap { (i, c) in c.name == baseName ? i : nil }
            guard dupIdx < sameBase.count else { return nil }
            let chosen = sameBase[dupIdx]
            hops.append(MenuHop(indexInParent: chosen, name: seg))
            current = current.children[chosen]
        }
        return hops
    }

    private static func parseDisambigSuffix(_ name: String) -> (base: String, dupIdx: Int?) {
        guard name.hasSuffix("]"),
              let bracketStart = name.lastIndex(of: "[")
        else { return (name, nil) }
        let idxStart = name.index(after: bracketStart)
        let idxEnd = name.index(before: name.endIndex)
        guard idxStart < idxEnd,
              let idx = Int(name[idxStart..<idxEnd])
        else { return (name, nil) }
        let base = String(name[..<bracketStart])
        return (base, idx)
    }

    /// Walk a hop sequence via the probe, dispatching `pressMenuItem` at each step.
    /// Each hop's path is the cumulative path segments seen so far.
    /// Aborts on first `pressMenuItem` returning false with `PluginError.pressFailedAt`.
    public static func selectMenuPath(_ hops: [MenuHop], probe: PluginPresetProbe, settleMs: Int = 300) async throws {
        var cumulative: [String] = []
        for (i, hop) in hops.enumerated() {
            cumulative.append(hop.name)
            let success = await probe.pressMenuItem(cumulative)
            if !success {
                throw PluginError.pressFailedAt(path: cumulative)
            }
            if i + 1 < hops.count {
                await probe.sleep(settleMs)
            }
        }
    }

    // MARK: - T4: Plugin Identity

    /// Decode an AU `AudioComponentGetVersion` raw `UInt32` (format `0xMMMMmmbb`) to
    /// a human-readable `"M.m.b"` string. Returns nil for `0` (Apple docs state 0 → unavailable).
    public static func decodeAUVersion(_ raw: UInt32) -> String? {
        guard raw != 0 else { return nil }
        let major = Int((raw >> 16) & 0xFFFF)
        let minor = Int((raw >> 8) & 0xFF)
        let bugfix = Int(raw & 0xFF)
        return "\(major).\(minor).\(bugfix)"
    }

    /// Find a plugin window for a given track index via the runtime.
    /// Returns nil if none match (e.g. track has no plugin, plugin window closed).
    /// Multi-window case (E26): runtime returns first match whose bundle ID aligns
    /// with the track's instrument slot; ordering is runtime-dependent.
    public static func findPluginWindow(for trackIndex: Int, runtime: PluginWindowRuntime) async -> AXUIElementSendable? {
        await runtime.findWindow(trackIndex)
    }

    /// Identify the plugin hosted by the given window via the runtime.
    /// Returns nil if identity cannot be determined (E31 — caller surfaces error).
    public static func identifyPlugin(in window: AXUIElementSendable, runtime: PluginWindowRuntime) async -> (name: String, bundleID: String, version: String?)? {
        await runtime.identifyPlugin(window)
    }

    // MARK: - T5: Plugin Window Lifecycle

    /// Open a plugin window for the given track via the runtime; poll until the
    /// window is visible, up to 2000 ms. Throws `PluginError.openTimeout` on
    /// timeout.
    /// Uses runtime's monotonic `nowMs` for timeout — survives NTP adjustments.
    public static func openPluginWindow(
        for trackIndex: Int,
        runtime: PluginWindowRuntime,
        probeSleep: @Sendable (Int) async -> Void,
        timeoutMs: Int = 2000
    ) async throws -> AXUIElementSendable {
        let startMs = runtime.nowMs()
        _ = try await runtime.openWindow(trackIndex)
        while true {
            if let window = await runtime.findWindow(trackIndex) {
                return window
            }
            let elapsedMs = runtime.nowMs() - startMs
            if elapsedMs >= timeoutMs {
                throw PluginError.openTimeout(trackIndex: trackIndex)
            }
            await probeSleep(100)
        }
    }

    /// Close a plugin window via the runtime. Returns true on success, false on failure
    /// (no throw — caller decides whether to log WARN or propagate).
    public static func closePluginWindow(_ window: AXUIElementSendable, runtime: PluginWindowRuntime) async -> Bool {
        await runtime.closeWindow(window)
    }

    // MARK: - Live AX helpers (T0 v0.6 empirical findings)

    /// Find the focused plugin window in Logic Pro's AX tree.
    /// Heuristic: any window whose title doesn't contain ".logicx" AND has an
    /// `AXPopUpButton` whose `value` contains "Preset"/"프리셋"/"Default" (the Setting dropdown).
    public static func findFocusedPluginWindowAX(in app: AXUIElement) -> AXUIElement? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement]
        else { return nil }
        for w in windows {
            var titleRaw: AnyObject?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRaw)
            let title = (titleRaw as? String) ?? ""
            if title.contains(".logicx") { continue }
            if findSettingPopupAX(in: w) != nil { return w }
        }
        return nil
    }

    /// Walk window children for the Setting `AXPopUpButton` (T0 v0.6: NOT AXMenuButton).
    /// Match by value containing "Preset"/"프리셋"/"Default".
    public static func findSettingPopupAX(in element: AXUIElement, depth: Int = 0, max: Int = 8) -> AXUIElement? {
        if depth > max { return nil }
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
        let role = (roleRaw as? String) ?? ""
        if role == (kAXPopUpButtonRole as String) {
            var valRaw: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRaw)
            let v = (valRaw as? String) ?? ""
            if v.contains("Preset") || v.contains("프리셋") || v.contains("Default") || v.contains("기본") {
                return element
            }
        }
        var childrenRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRaw)
        guard let children = childrenRaw as? [AXUIElement] else { return nil }
        for c in children {
            if let f = findSettingPopupAX(in: c, depth: depth + 1, max: max) { return f }
        }
        return nil
    }

    /// Read center-point of an AX element for CGEvent click.
    public static func centerPoint(of element: AXUIElement) -> CGPoint? {
        var posRaw: AnyObject?
        var sizeRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw)
        guard let posVal = posRaw, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRaw, CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue((posVal as! AXValue), .cgPoint, &p),
              AXValueGetValue((sizeVal as! AXValue), .cgSize, &s)
        else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }

    /// Find the currently-open Setting AXMenu in Logic's AX tree (it appears as
    /// a top-level AXMenu after the popup is opened via CGEvent click).
    public static func findOpenSettingMenuAX(in app: AXUIElement, minChildren: Int = 5) -> AXUIElement? {
        return findMenuRecursive(in: app, minChildren: minChildren, depth: 0, max: 5)
    }

    private static func findMenuRecursive(in element: AXUIElement, minChildren: Int, depth: Int, max: Int) -> AXUIElement? {
        if depth > max { return nil }
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
        if (roleRaw as? String) == (kAXMenuRole as String) {
            var kidsRaw: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kidsRaw)
            let count = (kidsRaw as? [AXUIElement])?.count ?? 0
            if count >= minChildren { return element }
        }
        var childrenRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRaw)
        guard let children = childrenRaw as? [AXUIElement] else { return nil }
        for c in children {
            if let f = findMenuRecursive(in: c, minChildren: minChildren, depth: depth + 1, max: max) { return f }
        }
        return nil
    }

    /// Build a live `PluginPresetProbe` driven by a real AXMenu element. Used by
    /// the `plugin.scan_presets` handler in `AccessibilityChannel`.
    /// - Important: T0 v0.6 — this probe does NOT use CGEvent for menu navigation;
    ///   only AXPress on AXMenuItem (which is reliable). The CGEvent click that
    ///   opened the popup is the caller's responsibility.
    public static func liveMenuProbe(rootMenu: AXUIElement, settleMs: Int = 250) -> PluginPresetProbe {
        // Cache the AXMenu element by path for re-use during the walk.
        // Each walk path is a sequence of segment names; we navigate via AXChildren.
        let rootBox = AXUIElementSendable(rootMenu)

        let menuItemsAt: @Sendable ([String]) async -> [PluginMenuItemInfo]? = { path in
            // Find the menu node at the given path (root if empty)
            guard let node = await navigateMenu(from: rootBox.element, path: path, settleMs: settleMs) else {
                return nil
            }
            // Read children; for each AXMenuItem, classify as folder/leaf/separator/action
            var rawKidsObj: AnyObject?
            AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &rawKidsObj)
            guard let kids = rawKidsObj as? [AXUIElement] else { return [] }
            return kids.compactMap { k in
                var rRaw: AnyObject?
                AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &rRaw)
                let role = (rRaw as? String) ?? ""
                guard role == "AXMenuItem" else { return nil }
                var nameRaw: AnyObject?
                AXUIElementCopyAttributeValue(k, kAXTitleAttribute as CFString, &nameRaw)
                let name = (nameRaw as? String) ?? ""
                // Probe for submenu by checking enabled + role + lazy-populate marker
                // We can't tell submenu vs leaf without pressing; use AXChildren as quick check first
                var kidsRaw: AnyObject?
                AXUIElementCopyAttributeValue(k, kAXChildrenAttribute as CFString, &kidsRaw)
                let hasSubmenu = ((kidsRaw as? [AXUIElement]) ?? []).contains(where: {
                    var rr: AnyObject?
                    AXUIElementCopyAttributeValue($0, kAXRoleAttribute as CFString, &rr)
                    return (rr as? String) == (kAXMenuRole as String)
                })
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    return PluginMenuItemInfo(name: name, kind: .separator, hasSubmenu: false)
                }
                if hasSubmenu {
                    return PluginMenuItemInfo(name: name, kind: .folder, hasSubmenu: true)
                }
                return PluginMenuItemInfo(name: name, kind: .leaf, hasSubmenu: false)
            }
        }

        let pressMenuItem: @Sendable ([String]) async -> Bool = { path in
            guard let node = await navigateMenu(from: rootBox.element, path: path, settleMs: settleMs) else {
                return false
            }
            let r = AXUIElementPerformAction(node, kAXPressAction as CFString)
            return r == .success
        }

        return PluginPresetProbe(
            menuItemsAt: menuItemsAt,
            pressMenuItem: pressMenuItem,
            focusOK: { true },          // assume OK during scan; mutation guard handles drift
            mutationSinceLastCheck: { false }, // single-scan pass; no detector here (T6 production adds)
            sleep: { ms in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            },
            visitedHash: { path in path.joined(separator: "/").hashValue }
        )
    }

    /// Walk the AXMenu tree from `rootMenu` along the given path, pressing each
    /// AXMenuItem to populate its submenu lazily.
    private static func navigateMenu(from root: AXUIElement, path: [String], settleMs: Int) async -> AXUIElement? {
        var cursor = root
        for seg in path {
            // Find child AXMenuItem with matching name
            var kidsRaw: AnyObject?
            AXUIElementCopyAttributeValue(cursor, kAXChildrenAttribute as CFString, &kidsRaw)
            guard let kids = kidsRaw as? [AXUIElement] else { return nil }
            // Disambiguate "Name[i]" suffix
            let (baseName, dupIdx) = parseDisambigSuffix(seg)
            let matches = kids.enumerated().filter { (_, k) in
                var nRaw: AnyObject?
                AXUIElementCopyAttributeValue(k, kAXTitleAttribute as CFString, &nRaw)
                let n = (nRaw as? String) ?? ""
                return n == seg || (dupIdx != nil && n == baseName)
            }
            guard !matches.isEmpty else { return nil }
            let chosen: AXUIElement
            if let dupIdx = dupIdx, dupIdx >= 0, dupIdx < matches.count {
                chosen = matches[dupIdx].element
            } else {
                chosen = matches[0].element
            }
            // Press to expand submenu (AXPress lazy-populate)
            _ = AXUIElementPerformAction(chosen, kAXPressAction as CFString)
            try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
            // Submenu appears as AXMenu child of pressed item
            var subRaw: AnyObject?
            AXUIElementCopyAttributeValue(chosen, kAXChildrenAttribute as CFString, &subRaw)
            guard let subKids = subRaw as? [AXUIElement] else { return nil }
            guard let menu = subKids.first(where: {
                var rr: AnyObject?
                AXUIElementCopyAttributeValue($0, kAXRoleAttribute as CFString, &rr)
                return (rr as? String) == (kAXMenuRole as String)
            }) else { return nil }
            cursor = menu
        }
        return cursor
    }
}
