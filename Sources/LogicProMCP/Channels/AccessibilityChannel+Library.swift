import ApplicationServices
import AppKit
import Foundation

/// Library surface (library.*, plugin.scan_presets, track.set_instrument): panel/disk scans, path resolution, and instrument routing.
extension AccessibilityChannel {
    // MARK: - Library operations

    static func listLibrary(
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let inventory = LibraryAccessor.enumerate(runtime: runtime) else {
            return .error("Library panel not found. Open Library (Y) in Logic Pro.")
        }
        do {
            let data = try JSONEncoder().encode(inventory)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to serialize library inventory")
            }
            return .success(json)
        } catch {
            return .error("JSON encode failed: \(error)")
        }
    }


    /// Shared JSON encoder path used by disk / ax scan success branches so
    /// both modes emit identical formatting (sorted keys, no pretty-print).
    /// v3.1.0 (T6) — callers pass a `sourceTag` (panel|disk|both) that gets
    /// merged into the response envelope so clients can tell which scanner
    /// produced the tree without needing `scan_library` params echoed back.
    static func encodeLibraryRoot(
        _ root: LibraryRoot, sourceTag: String = "panel"
    ) -> ChannelResult {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(root)
            guard let s = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode library inventory JSON")
            }
            // Wrap the raw LibraryRoot JSON in an envelope that names the
            // source scanner. Additive: legacy consumers that parsed the
            // raw root now must read `.root`, but the field is present
            // regardless of source so the schema is stable.
            let wrapped = "{\"source\":\"\(sourceTag)\",\"root\":\(s)}"
            return .success(wrapped)
        } catch {
            return .error("JSON encode failed: \(error)")
        }
    }

    // MARK: - F2 plugin.scan_presets minimal handler (T0 verdict MIXED)

    /// Production `plugin.scan_presets` path — relies on currently-focused plugin
    /// window. CGEvent-clicks the Setting popup to open the menu, then walks via
    /// AXPress on AXMenuItems (T0 v0.6 empirical — popup AXPress unreliable, menu
    /// item AXPress 100% reliable). Returns serialized PluginPresetNode tree.
    /// Full T6 (cache, persistence, identity gate) is follow-up.
    static func runLivePluginPresetScan(
        runtime: AXLogicProElements.Runtime,
        settleMs: Int = 250
    ) async -> ChannelResult {
        // 1. Resolve Logic app root
        guard let appRoot = AXLogicProElements.appRoot(runtime: runtime) else {
            return .error("Logic Pro is not running")
        }
        // 2. Find focused plugin window (heuristic: has AXPopUpButton with "Preset"/"기본" value)
        guard let pluginWin = PluginInspector.findFocusedPluginWindowAX(in: appRoot) else {
            return .error("No plugin window with Setting dropdown found. Open an instrument plugin window first.")
        }
        // 3. Locate Setting popup
        guard let popup = PluginInspector.findSettingPopupAX(in: pluginWin) else {
            return .error("Setting popup not found in plugin window")
        }
        // 4. Open the menu — AX-first ladder. AXShowMenu is the canonical popup
        //    action per NSAccessibility; AXPress sometimes works on Logic's
        //    custom popups; CGEvent click is the last-resort fallback.
        //    T0 verdict (v0.6) said raw AXPress was unreliable — we re-test here
        //    and only fall through to CGEvent if both AX actions fail to surface
        //    the AXMenu within the settle window.
        var menu: AXUIElement?
        let axOpenActions = [kAXShowMenuAction, kAXPressAction]
        for action in axOpenActions {
            if AXHelpers.performAction(popup, action, runtime: runtime.ax) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let found = PluginInspector.findOpenSettingMenuAX(in: appRoot) {
                    menu = found
                    break
                }
            }
        }
        if menu == nil {
            guard let center = PluginInspector.centerPoint(of: popup) else {
                return .error("Setting popup has no readable position/size; AXShowMenu/AXPress also failed")
            }
            guard LibraryAccessor.productionMouseClick(at: center) else {
                return .error("AXShowMenu/AXPress failed and CGEvent click on Setting popup also failed (Post-Event permission?)")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            menu = PluginInspector.findOpenSettingMenuAX(in: appRoot)
        }
        guard let menu = menu else {
            return .error("Setting menu did not appear after AXShowMenu/AXPress/CGEvent (or already dismissed)")
        }
        // 6. Build live probe + walk
        let probe = PluginInspector.liveMenuProbe(rootMenu: menu, settleMs: settleMs)
        let scanStart = Date()
        do {
            let (root, cycleCount) = try await PluginInspector.enumerateMenuTree(
                probe: probe, maxDepth: maxPluginMenuDepth, settleMs: settleMs
            )
            let durationMs = Int(Date().timeIntervalSince(scanStart) * 1000)
            // 7. Dismiss menu
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            // 8. Compute counts
            let counts = AccessibilityChannel.countNodes(root)
            // 9. Build minimal cache (no persistence in this minimal handler)
            let cache = PluginPresetCache(
                schemaVersion: 1,
                pluginName: "(focused-plugin)",
                pluginIdentifier: "(unknown — T6 will resolve via AU registry)",
                pluginVersion: nil,
                contentHash: "(deferred)",
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                scanDurationMs: durationMs,
                measuredSubmenuOpenDelayMs: settleMs,
                truncatedBranches: counts.truncated,
                probeTimeouts: counts.probeTimeout,
                cycleCount: cycleCount,
                nodeCount: counts.total,
                leafCount: counts.leaf,
                folderCount: counts.folder,
                root: root
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            guard let s = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode plugin preset cache JSON")
            }
            return .success(s)
        } catch PluginError.menuMutated {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            return .error("Plugin menu mutated mid-scan; aborted")
        } catch PluginError.focusLost {
            return .error("Logic Pro lost focus mid-scan")
        } catch {
            return .error("Plugin scan failed: \(error)")
        }
    }

    /// Walk a `PluginPresetNode` tree and tally counts by kind.
    private static func countNodes(_ node: PluginPresetNode) -> (total: Int, leaf: Int, folder: Int, truncated: Int, probeTimeout: Int) {
        var total = 1
        var leaf = node.kind == .leaf ? 1 : 0
        var folder = node.kind == .folder ? 1 : 0
        var truncated = node.kind == .truncated ? 1 : 0
        var probeTimeout = node.kind == .probeTimeout ? 1 : 0
        for c in node.children {
            let s = countNodes(c)
            total += s.total
            leaf += s.leaf
            folder += s.folder
            truncated += s.truncated
            probeTimeout += s.probeTimeout
        }
        return (total, leaf, folder, truncated, probeTimeout)
    }

    /// Detects external (non-scanner) mutation of the Library panel during a scan.
    /// Compares column-1 category list against a snapshot taken at scan start.
    /// Scanner's own `selectCategory` clicks change column 2 content only — column 1
    /// category list is invariant under scanner actions.
    private final class MutationDetector: @unchecked Sendable {
        private let runtime: AXLogicProElements.Runtime
        private let initialCategories: [String]
        init(runtime: AXLogicProElements.Runtime) {
            self.runtime = runtime
            self.initialCategories = LibraryAccessor.enumerate(runtime: runtime)?.categories ?? []
        }
        func check() -> Bool {
            let current = LibraryAccessor.enumerate(runtime: runtime)?.categories ?? []
            return current != initialCategories
        }
    }

    /// Build a live TreeProbe for the current flat 2-level Logic Library:
    /// depth 0 → categories; depth 1 → click category + read presets; depth 2+ → leaf.
    ///
    /// v3.0.4 NOTE: The 14× undercount of `scan_library` (345 leaves vs 4,891+
    /// disk `.patch` files) is caused by the `return []` at depth 2+ in this
    /// probe. A correct deep scan requires a non-destructive
    /// folder-vs-leaf discriminator BEFORE clicking, because clicking a
    /// preset-leaf in Logic's Library actually loads it onto the focused
    /// track — you cannot "probe by clicking" without mutating the user's
    /// project. The discriminator exists in the AX tree (column-2 items
    /// have an `AXDisclosureTriangle` sibling or an `AXChildren` attribute
    /// for subfolders; leaves have neither) but live-characterising Logic's
    /// exact AX exposure safely requires an offline probe session which was
    /// not available for v3.0.4.
    ///
    /// v3.0.5 RESOLUTION: This AX probe is no longer the default path —
    /// `library.scan_all` defaults to `{mode:"disk"}` which enumerates the
    /// factory Library bundle on disk (no click, no mutation, full coverage).
    /// This AX probe is preserved for `{mode:"ax"}` (legacy clients and diff
    /// mode) and still carries its 2-level limitation.
    static func buildLiveTreeProbe(runtime: AXLogicProElements.Runtime) -> TreeProbe {
        let logicPID = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.logic10"
        })?.processIdentifier
        let detector = MutationDetector(runtime: runtime)
        return TreeProbe(
            childrenAt: { path in
                if path.isEmpty {
                    guard let inv = LibraryAccessor.enumerate(runtime: runtime) else { return nil }
                    return inv.categories
                }
                if path.count == 1 {
                    guard LibraryAccessor.selectCategory(named: path[0], runtime: runtime) else {
                        return nil
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    return LibraryAccessor.currentPresets(runtime: runtime)
                }
                return []
            },
            focusOK: {
                guard let pid = logicPID else { return true }
                let sysWide = AXUIElementCreateSystemWide()
                var focusedApp: AnyObject?
                let r = AXUIElementCopyAttributeValue(
                    sysWide, kAXFocusedApplicationAttribute as CFString, &focusedApp
                )
                guard r == .success, let app = focusedApp,
                      CFGetTypeID(app) == AXUIElementGetTypeID() else { return true }
                let focusedElement = app as! AXUIElement
                var appPID: pid_t = 0
                AXUIElementGetPid(focusedElement, &appPID)
                return appPID == pid
            },
            mutationSinceLastCheck: { detector.check() },
            sleep: { ms in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            },
            visitedHash: { path in
                path.joined(separator: "\u{0001}").hashValue
            }
        )
    }

    /// v3.0.6 — size threshold that triggers a warn-level log on encode. We
    /// do not truncate or paginate (would break schema); just surface the
    /// signal so the next maintenance window can decide whether to chunk.
    private static let inventoryWarnBytes = 1_048_576   // 1 MiB

    /// Tag the encoded JSON with a `source` marker so downstream consumers
    /// can tell whether the file came from an AX scan (Panel-authoritative,
    /// may undercount) or a disk scan (full coverage, Panel-taxonomy mapped).
    /// The v3.0.5 bug was that the disk-mode path silently overwrote the
    /// AX-canonical file with no version tag. v3.0.6 also writes disk scans
    /// to a distinct file (`library-inventory-disk.json`) so the AX snapshot
    /// remains untouched unless explicitly refreshed by an AX scan.
    ///
    /// - Parameters:
    ///   - root: the LibraryRoot payload.
    ///   - source: either `"ax"` or `"disk"`. Controls both the embedded
    ///     `"source"` field and the destination filename.
    /// - Returns: true iff the file was written successfully.
    static func writeInventoryJSON(_ root: LibraryRoot, source: String = "ax") -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard var rootData = try? encoder.encode(root) else { return false }

        // Inject a top-level `"source"` field by rewriting the outermost
        // `{` to `{ "source": "...",`. Cheaper than reflecting the whole
        // LibraryRoot into a dictionary, and avoids perturbing the Codable
        // contract used by clients that deserialize LibraryRoot directly
        // from a `scan_all` MCP response.
        let injection = "\n  \"source\" : \"\(source)\",".data(using: .utf8) ?? Data()
        // Find the first `{` byte and splice after it.
        if let firstBraceIdx = rootData.firstIndex(of: UInt8(ascii: "{")) {
            rootData.insert(contentsOf: injection, at: rootData.index(after: firstBraceIdx))
        }

        if rootData.count > inventoryWarnBytes {
            Log.warn(
                "Library inventory JSON is \(rootData.count) bytes (>1MiB); consider paginating library.scan_all in a future release",
                subsystem: "library"
            )
        }

        let fm = FileManager.default
        let resDir = fm.currentDirectoryPath + "/Resources"
        if !fm.fileExists(atPath: resDir) {
            try? fm.createDirectory(atPath: resDir, withIntermediateDirectories: true)
        }
        // Disk scans go to a distinct file so an AX snapshot survives a
        // disk scan. AX scans own the canonical filename.
        let filename = source == "disk" ? "library-inventory-disk.json" : "library-inventory.json"
        let path = resDir + "/" + filename
        do {
            try rootData.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            Log.warn("Library inventory write failed: \(error)", subsystem: "library")
            return false
        }
    }

    /// T6: compute the vertical viewport of the track list (Y min/max on screen).
    /// Returns nil if the scroll area isn't resolvable — callers fall through
    /// to click anyway (fail-open, documented in T6 EC-1).
    private static func trackViewport(runtime: AXLogicProElements.Runtime) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let headers = AXLogicProElements.getTrackHeaders(runtime: runtime) else { return nil }
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(headers, kAXPositionAttribute as CFString, &posValue)
        _ = AXUIElementCopyAttributeValue(headers, kAXSizeAttribute as CFString, &sizeValue)
        // H2 (P2-5): fail-closed on non-AXValue / wrong-subtype rather than
        // deriving a (0,0)-based viewport.
        guard let p = AXHelpers.point(fromRawAttribute: posValue),
              let s = AXHelpers.size(fromRawAttribute: sizeValue) else { return nil }
        return (p.y, p.y + s.height)
    }

    private struct ResolvePathResponse: Encodable {
        let exists: Bool
        let kind: String?
        let matchedPath: String?
        let children: [String]?
        let reason: String?
        // v3.1.0 (T6) — when a panel cache is present and the match comes from
        // disk only, `source` is `"disk-only"` and `loadable` is false so
        // clients know not to attempt `set_instrument` on a panel-missing path.
        // Without a panel cache, disk leaf paths are loadable candidates; the
        // actual apply still has to be verified by `set_instrument`.
        // When the match exists in the panel scan (or we only have a panel
        // scan), `source` is `"panel"` and `loadable` is true.
        let source: String?
        let loadable: Bool?
        let warning: String?
    }

    private struct SetInstrumentResponse: Encodable {
        let category: String
        let preset: String
        let path: String
    }

    /// v3.1.0 (T2) — read back the Library Panel's currently-selected preset
    /// and compare against the just-requested leaf. Used by `setTrackInstrument`
    /// to produce an Honest Contract 3-state response. Returns the observed
    /// preset name (or nil when the panel doesn't expose a current-selection
    /// attribute, which we treat as `readback_unavailable`).
    static func readBackLibraryPreset(
        runtime: AXLogicProElements.Runtime = .production
    ) -> String? {
        let inv = LibraryAccessor.enumerate(runtime: runtime)
        return inv?.currentPreset
    }

    static func resolveLibraryPath(
        params: [String: String],
        lastPanelScan: LibraryRoot?,
        lastDiskScan: LibraryRoot?,
        lastScan: LibraryRoot?,
        lastScanSource: String?
    ) -> ChannelResult {
        guard let path = params["path"], !path.isEmpty else {
            return .error("Missing 'path' parameter for library.resolve_path")
        }
        // v3.1.0 (T6) + #222 — resolution ladder:
        //  1. If panel cache has the path, return source:"panel"; loadable is
        //     true only for leaf nodes. Folder/category rows are browse rows,
        //     not set_instrument targets.
        //  2. Else if disk cache has it and no panel cache exists, return
        //     source:"disk"; leaf paths are loadable candidates, folders are
        //     non-loadable browse rows.
        //  3. Else if disk cache has it but panel cache missed it, return
        //     source:"disk-only", loadable:false + warning.
        //  4. Else fall back to the legacy `lastScan` (whatever was written
        //     most recently) so callers that only ran one scan still work.
        //  5. Else return exists:false.
        // Panel cache: take the hit only if the path exists there. A
        // `PathResolution(exists:false)` means the segment wasn't found in
        // the panel tree — fall through to the disk cache before declaring
        // the entry unloadable.
        if let root = lastPanelScan,
           let res = LibraryAccessor.resolvePath(path, in: root), res.exists {
            let diskOverride = lastDiskScan
                .flatMap { LibraryAccessor.resolvePath(path, in: $0) }
                .flatMap { diskRes in
                    diskRes.exists && diskRes.kind != .leaf ? diskRes : nil
                }
            let effectiveKind = diskOverride?.kind ?? res.kind
            let effectiveMatchedPath = diskOverride?.matchedPath ?? res.matchedPath
            let effectiveChildren = diskOverride?.children ?? res.children
            let loadable = effectiveKind == .leaf
            return encodeResult(ResolvePathResponse(
                exists: true, kind: effectiveKind?.rawValue,
                matchedPath: effectiveMatchedPath, children: effectiveChildren,
                reason: loadable ? nil : Self.nonLoadableReason(for: effectiveKind),
                source: "panel",
                loadable: loadable,
                warning: loadable ? nil : Self.nonLoadableWarning(path: path, kind: effectiveKind)
            ))
        }
        if let root = lastDiskScan,
           let res = LibraryAccessor.resolvePath(path, in: root), res.exists {
            let hasPanelCache = lastPanelScan != nil
            let isLoadableDiskCandidate = !hasPanelCache && res.kind == .leaf
            let source = hasPanelCache ? "disk-only" : "disk"
            let warning: String?
            if isLoadableDiskCandidate {
                warning = nil
            } else if hasPanelCache {
                warning = "Path exists on disk but isn't exposed via Logic's Library Panel. set_instrument will fail for this entry; run scan_library with mode=ax to see Panel-loadable paths."
            } else {
                warning = Self.nonLoadableWarning(path: path, kind: res.kind)
            }
            return encodeResult(ResolvePathResponse(
                exists: true, kind: res.kind?.rawValue,
                matchedPath: res.matchedPath, children: res.children,
                reason: isLoadableDiskCandidate ? nil : Self.nonLoadableReason(for: res.kind),
                source: source,
                loadable: isLoadableDiskCandidate,
                warning: warning
            ))
        }
        // Legacy fallback — use whatever cache was last populated.
        guard let root = lastScan else {
            return encodeResult(ResolvePathResponse(
                exists: false, kind: nil, matchedPath: nil, children: nil,
                reason: "No cached library scan; call scan_library first",
                source: nil, loadable: nil, warning: nil
            ))
        }
        guard let res = LibraryAccessor.resolvePath(path, in: root) else {
            return encodeResult(ResolvePathResponse(
                exists: false, kind: nil, matchedPath: nil, children: nil,
                reason: nil, source: lastScanSource, loadable: nil, warning: nil
            ))
        }
        // If lastScanSource is "disk" or "both" and we didn't find the path
        // in lastPanelScan above, treat as disk-only.
        let isPanelLoadable = lastScanSource == "panel" && res.exists && res.kind == .leaf
        let warning: String?
        if isPanelLoadable {
            warning = nil
        } else if lastScanSource == "panel", res.exists {
            warning = Self.nonLoadableWarning(path: path, kind: res.kind)
        } else {
            warning = "Path resolved from \(lastScanSource ?? "unknown") cache; may not be loadable via Library Panel."
        }
        return encodeResult(ResolvePathResponse(
            exists: res.exists,
            kind: res.kind?.rawValue,
            matchedPath: res.matchedPath,
            children: res.children,
            reason: isPanelLoadable ? nil : Self.nonLoadableReason(for: res.kind),
            source: lastScanSource,
            loadable: isPanelLoadable,
            warning: warning
        ))
    }

    private static func nonLoadableReason(for kind: LibraryNodeKind?) -> String? {
        guard let kind, kind != .leaf else { return nil }
        return kind == .folder ? "folder_path" : "not_loadable_path"
    }

    private static func nonLoadableWarning(path: String, kind: LibraryNodeKind?) -> String {
        let kindLabel = kind?.rawValue ?? "unknown"
        return "Library path '\(path)' resolves to \(kindLabel); set_instrument accepts only leaf preset paths."
    }

    /// Injectable staging seam for `setTrackInstrument`'s Library-panel
    /// precondition + path pre-resolution. Production wires live AX reads + a
    /// View-menu auto-open; tests inject deterministic outcomes (panel closed/open,
    /// path present/absent) without driving real Logic UI. #131/#135/#141.
    struct LibraryPanelStaging: Sendable {
        /// Read-only: is the Library panel currently open?
        let isPanelOpen: @Sendable (AXLogicProElements.Runtime) -> Bool
        /// Attempt to open the Library panel (View > Show Library). Best
        /// effort; the caller re-checks `isPanelOpen` afterwards.
        let openPanel: @Sendable (AXLogicProElements.Runtime) async -> Void
        let resolvePathKind: @Sendable (String) -> LibraryNodeKind?
        /// Pre-resolve the requested path against the cached inventory WITHOUT
        /// touching live AX. Returns:
        ///   .some(true)  → path is known to EXIST in the cache (attempt nav)
        ///   .some(false) → path is known to be ABSENT (fail closed, do not nav)
        ///   nil          → no cache available / cannot decide (attempt nav)
        let resolvePath: @Sendable (String) -> Bool?

        init(
            isPanelOpen: @Sendable @escaping (AXLogicProElements.Runtime) -> Bool,
            openPanel: @Sendable @escaping (AXLogicProElements.Runtime) async -> Void,
            resolvePathKind: @Sendable @escaping (String) -> LibraryNodeKind? = { _ in nil },
            resolvePath: @Sendable @escaping (String) -> Bool?
        ) {
            self.isPanelOpen = isPanelOpen
            self.openPanel = openPanel
            self.resolvePathKind = resolvePathKind
            self.resolvePath = resolvePath
        }

        static let production = LibraryPanelStaging(
            isPanelOpen: { rt in LibraryAccessor.isLibraryPanelOpen(runtime: rt) },
            openPanel: { rt in await AccessibilityChannel.openLibraryPanelViaKeyCommand(runtime: rt) },
            // Static call site has no instance cache; the channel wires a
            // cache-backed resolver at the dispatch site. Default = undecided.
            resolvePath: { _ in nil }
        )
    }

    /// Best-effort Library-panel open via the View menu. Avoid user key-command
    /// mappings here because live #222 testing showed shortcut drift can open
    /// Controller Assignments instead of the Library panel.
    /// No verification here — the caller re-checks `isLibraryPanelOpen` after
    /// a settle. v3.6.x (#131/#135/#141), hardened for #222.
    static func openLibraryPanelViaKeyCommand(
        runtime: AXLogicProElements.Runtime = .production
    ) async {
        _ = ProcessUtils.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)
        _ = await clickLibraryMenuItem(runtime: runtime)
    }

    private static func clickLibraryMenuItem(runtime: AXLogicProElements.Runtime) async -> Bool {
        guard let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
              let viewMenu = AXLocalePolicy.findMenuBarItem(
                in: menuBar,
                matching: AXLocalePolicy.viewMenuBar,
                runtime: runtime.ax
              ) else {
            return false
        }

        if !clickAXElementCenter(viewMenu, runtime: runtime.ax),
           !AXHelpers.performAction(viewMenu, kAXPressAction as String, runtime: runtime.ax) {
            return false
        }
        try? await Task.sleep(nanoseconds: 120_000_000)

        let libraryMenuItem = AXLocalePolicy.LabelSet(
            canonical: "Show Library",
            variants: ["라이브러리 보기", "라이브러리"],
            rationale: "Logic exposes View menu items as localized AX titles without stable identifiers."
        )
        guard let item = AXLocalePolicy.findMenuItem(
            under: viewMenu,
            matching: libraryMenuItem,
            mode: .exact,
            runtime: runtime.ax
        ) else {
            AXMouseHelper.pressEscape()
            return false
        }

        if let enabled: Bool = AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: runtime.ax),
           !enabled {
            AXMouseHelper.pressEscape()
            return false
        }

        if clickAXElementCenter(item, runtime: runtime.ax)
            || AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax) {
            return true
        }
        AXMouseHelper.pressEscape()
        return false
    }

    private static func clickAXElementCenter(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        guard let pos = AXHelpers.getPosition(element, runtime: runtime),
              let size = AXHelpers.getSize(element, runtime: runtime),
              size.width > 0, size.height > 0 else {
            return false
        }
        return LibraryAccessor.productionMouseClick(
            at: CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        )
    }

    /// One-shot, thread-safe latch so a deadline race resumes its continuation
    /// exactly once. #131 robustness.
    private final class DeadlineLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    static let setInstrumentLibraryNavigationDeadlineSeconds: Double = 30

    /// Run a blocking Library-navigation closure under a hard wall-clock
    /// deadline. Returns the closure's result, or `nil` if the deadline elapsed
    /// first. The closure runs on a global queue (never the cooperative pool) so
    /// a wedged AX surface can't stall the stdio loop; if it overruns it is
    /// abandoned (the operation still returns bounded) rather than hanging
    /// indefinitely. #131 — set_instrument must never hang on an unresponsive
    /// Library panel.
    private static func runWithDeadline(
        seconds: Double,
        _ work: @escaping @Sendable () -> Bool
    ) async -> Bool? {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let latch = DeadlineLatch()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                if latch.claim() { cont.resume(returning: result) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if latch.claim() { cont.resume(returning: nil) }
            }
        }
    }

    static func setTrackInstrument(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        staging: LibraryPanelStaging = .production
    ) async -> ChannelResult {
        // Resolve path-OR-legacy. Path wins when both provided.
        let pathParam = params["path"].flatMap { $0.isEmpty ? nil : $0 }
        let catParam = params["category"].flatMap { $0.isEmpty ? nil : $0 }
        let presetParam = params["preset"].flatMap { $0.isEmpty ? nil : $0 }

        // v3.0.4 — N-segment navigation. Logic's Library is a 2-column sliding
        // "finder column" view: top-level Bass has 4 presets, top-level
        // Synthesizer has 14 subfolders (Arpeggiated, Bass, Lead, Pad, …) and
        // each of those subfolders holds the actual preset leaves. Pre-3.0.4
        // logic took `parts[0]` + `parts[last]` which dropped all middle
        // segments — so `Synthesizer/Bass/Acid Etched Bass` resolved to
        // category=Synthesizer, preset=Acid Etched Bass, and failed because
        // column 2 at that point only held Synthesizer's subfolders.
        let pathSegments: [String]
        let resolvedPath: String
        if let p = pathParam {
            guard let parts = LibraryAccessor.parsePath(p), parts.count >= 2 else {
                return .error("Invalid 'path': must have at least 2 segments (e.g. 'Bass/Sub Bass' or 'Synthesizer/Bass/Acid Etched Bass')")
            }
            pathSegments = parts
            resolvedPath = p
        } else if let c = catParam, let pr = presetParam {
            pathSegments = [c, pr]
            resolvedPath = "\(c)/\(pr)"
        } else {
            return .error("Missing path or (category+preset) for track.set_instrument")
        }
        let category = pathSegments[0]
        let preset = pathSegments[pathSegments.count - 1]
        let requestedTrackIndex: Int?
        if let indexStr = params["index"] {
            guard let index = Int(indexStr), index >= 0 else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: "track.set_instrument 'index' must be a non-negative integer",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: NSNull(),
                        targetTrackName: NSNull()
                    )
                ))
            }
            requestedTrackIndex = index
        } else {
            requestedTrackIndex = nil
        }

        // v3.0.3+ — select target track via the Apple-public AX-first
        // selection ladder (AXPress → AXSelected → child AXPress → coord
        // click fallback). Logic must be frontmost for the last step to
        // register, so activate first regardless of which step ends up
        // committing.
        _ = ProcessUtils.Runtime.production.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)   // window raise settle

        var targetTrackIndex = requestedTrackIndex
        var targetTrackName: Any = NSNull()

        if let index = requestedTrackIndex {
            guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
                return .error(HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "Track at index \(index) not found",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: index,
                        targetTrackName: NSNull()
                    )
                ))
            }
            if let name = AXLogicProElements.trackName(at: index, runtime: runtime) {
                targetTrackName = name
            }
            if !CGPreflightPostEventAccess() {
                return .error("Event-post permission required (Accessibility → Input Monitoring). Grant in System Settings.")
            }
            guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "Failed to select track \(index) before instrument load",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: index,
                        targetTrackName: targetTrackName
                    )
                ))
            }

            let selectionVerification = await verifyTrackSelection(index: index, runtime: runtime)
            if let refreshedName = AXLogicProElements.trackName(at: index, runtime: runtime) {
                targetTrackName = refreshedName
            }
            let selectionBase = setInstrumentBaseExtras(
                requestedPath: resolvedPath,
                category: category,
                preset: preset,
                targetTrackIndex: index,
                targetTrackName: targetTrackName
            )
            switch selectionVerification {
            case .verified:
                break
            case .selectionMetadataUnavailable:
                return .error(HonestContract.encodeStateC(
                    error: .trackSelectionFailed,
                    hint: "Track \(index) selection could not be verified before instrument load",
                    extras: selectionBase.merging([
                        "observed": NSNull(),
                        "observed_patch_name": NSNull(),
                        "target_track_selection_verified": false,
                        "target_track_selection_reason": HonestContract.UncertainReason.retryExhausted.rawValue,
                        "target_track_selection_observed_index": NSNull(),
                        "target_track_selection_verify_source": "ax_selected"
                    ]) { _, new in new }
                ))
            case .mismatch(let selectedIndex):
                return .error(HonestContract.encodeStateC(
                    error: .trackSelectionFailed,
                    hint: "Track \(index) selection settled on a different track before instrument load",
                    extras: selectionBase.merging([
                        "observed": NSNull(),
                        "observed_patch_name": NSNull(),
                        "target_track_selection_verified": false,
                        "target_track_selection_reason": HonestContract.UncertainReason.readbackMismatch.rawValue,
                        "target_track_selection_observed_index": selectedIndex as Any? ?? NSNull(),
                        "target_track_selection_verify_source": "ax_selected"
                    ]) { _, new in new }
                ))
            case .trackDisappeared:
                return .error(HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "Track at index \(index) disappeared during selection verification",
                    extras: selectionBase.merging([
                        "observed": NSNull(),
                        "observed_patch_name": NSNull(),
                        "target_track_selection_verified": false,
                        "target_track_selection_reason": HonestContract.UncertainReason.readbackUnavailable.rawValue,
                        "target_track_selection_observed_index": NSNull(),
                        "target_track_selection_verify_source": "ax_selected"
                    ]) { _, new in new }
                ))
            }

            try? await Task.sleep(nanoseconds: 300_000_000)   // Library rebind to new track
        } else if let selectedTrack = selectedTrackIdentity(runtime: runtime) {
            targetTrackIndex = selectedTrack.index
            targetTrackName = selectedTrack.name ?? NSNull()
        }

        // #131 — TRACK-TYPE awareness. Loading a software-instrument Library
        // patch onto a GM Device / External MIDI strip is not a supported
        // operation: those lanes route to a General-MIDI device and bounce
        // silent (root cause of #128). Detect the unsupported target up front
        // and fail closed with a TYPED `unsupported_track_type` error instead
        // of letting selectPath produce the misleading "Library path not fully
        // resolvable". Only enforced when we have a concrete target index whose
        // header we can read; an indeterminate target falls through unchanged.
        if let idx = targetTrackIndex,
           let header = AXLogicProElements.findTrackHeader(at: idx, runtime: runtime) {
            let observedType = AXValueExtractors.extractTrackState(
                from: header, index: idx, runtime: runtime.ax
            ).type
            if observedType == .externalMIDI {
                return .error(HonestContract.encodeStateC(
                    error: .unsupportedTrackType,
                    hint: "Target track \(idx) is a GM Device / External MIDI strip; software-instrument Library patches cannot be loaded onto it. Target a Software Instrument track instead.",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: idx,
                        targetTrackName: targetTrackName
                    ).merging([
                        "observed_track_type": observedType.rawValue,
                        "precondition": "wrong_target_type"
                    ]) { _, new in new }
                ))
            }
        }

        // #135/#141 — Library-panel PRECONDITION. selectPath walks AXStaticText
        // rows in the VISIBLE Library browser; if the panel is closed those
        // rows do not exist and selectPath fails with the misleading
        // "Library path not fully resolvable" even when the path is valid.
        // Mirror scan_all's guard: if the panel is closed, try to auto-open it
        // (Y), settle, and re-check; if it still cannot be staged, fail closed
        // with a TYPED `library_panel_unavailable` error and an actionable hint
        // — NOT ax_write_failed.
        if !staging.isPanelOpen(runtime) {
            await staging.openPanel(runtime)
            try? await Task.sleep(nanoseconds: 400_000_000)   // panel slide-in settle
            if !staging.isPanelOpen(runtime) {
                return .error(HonestContract.encodeStateC(
                    error: .libraryPanelUnavailable,
                    hint: "Library panel not found. Open Library (Y) in Logic Pro, then retry.",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                        targetTrackName: targetTrackName
                    ).merging(["precondition": "panel_closed"]) { _, new in new }
                ))
            }
        }

        // #135/#141 — PRE-RESOLVE the requested path against the cached
        // inventory (read-only, no live AX). This distinguishes a genuine
        // "path does not exist" (terminal precondition — do NOT attempt nav)
        // from "path exists but live AX nav failed" (still surfaces below as
        // ax_write_failed, a retry/timing signal). `resolvePath` returns nil
        // when no cache is available, in which case we attempt nav as before.
        if let pathKind = staging.resolvePathKind(resolvedPath), pathKind != .leaf {
            return .error(HonestContract.encodeStateC(
                error: .folderNotPreset,
                hint: "Library path '\(resolvedPath)' resolves to a \(pathKind.rawValue), not a loadable preset leaf. Pick a leaf path below it from scan_library.",
                extras: setInstrumentBaseExtras(
                    requestedPath: resolvedPath,
                    category: category,
                    preset: preset,
                    targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                    targetTrackName: targetTrackName
                ).merging([
                    "precondition": "folder_path",
                    "path_kind": pathKind.rawValue,
                ]) { _, new in new }
            ))
        }
        if staging.resolvePath(resolvedPath) == false {
            return .error(HonestContract.encodeStateC(
                error: .pathNotInLibrary,
                hint: "Library path '\(resolvedPath)' was not found in the scanned inventory. Run scan_library and pick an existing path.",
                extras: setInstrumentBaseExtras(
                    requestedPath: resolvedPath,
                    category: category,
                    preset: preset,
                    targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                    targetTrackName: targetTrackName
                ).merging(["precondition": "missing_path"]) { _, new in new }
            ))
        }

        // v3.0.4 — walk every segment in order. For 2-segment paths this
        // behaves exactly like the prior selectCategory + selectPreset pair.
        // For 3+ segment paths (Synthesizer/Bass/Acid Etched Bass), each
        // intermediate segment slides the Library view so the next segment's
        // column-2 lookup resolves against the correct subfolder.
        // #131 robustness — bound the live Library navigation with a hard
        // deadline. An invalid path (or a panel left in a bad state by a prior
        // invalid attempt) can make the AX traversal stall far past any client
        // timeout, hanging the stdio loop. Fail closed with a typed State C
        // instead of hanging. The happy path resolves in a few seconds, well
        // under this ceiling.
        let navOutcome = await AccessibilityChannel.runWithDeadline(
            seconds: Self.setInstrumentLibraryNavigationDeadlineSeconds
        ) {
            LibraryAccessor.selectPath(segments: pathSegments, runtime: runtime)
        }
        guard let didSelect = navOutcome else {
            // #222 — leave the Library panel in a known-open baseline before
            // returning, so a subsequent set_instrument is not poisoned by a
            // panel the abandoned navigation left closed/wedged (the reported
            // cascade: later attempts saw `library_panel_unavailable` even after
            // re-opening). See `restageLibraryPanelAfterFailure`.
            let restaged = await Self.restageLibraryPanelAfterFailure(staging: staging, runtime: runtime)
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "set_instrument Library navigation exceeded \(Int(Self.setInstrumentLibraryNavigationDeadlineSeconds))s and was abandoned — the Library panel's AX surface is unresponsive (a prior invalid-path attempt can leave it wedged). Re-open the Library (Y) and retry; restart Logic if it persists. Run scan_library first so an unknown path fails fast as path_not_in_library instead of navigating live.",
                extras: setInstrumentBaseExtras(
                    requestedPath: resolvedPath,
                    category: category,
                    preset: preset,
                    targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                    targetTrackName: targetTrackName
                ).merging([
                    "precondition": "library_nav_timeout",
                    "panel_open_after_failure": restaged.panelOpen,
                    "panel_restaged_after_failure": restaged.reopened,
                ]) { _, new in new }
            ))
        }
        guard didSelect else {
            // v3.1.0 (T2) — `selectPath` returns false when any segment's AX
            // write failed OR the segment's AXStaticText was not found in the
            // currently-visible browser. Both are hard failures — the patch
            // never loaded.
            //
            // v3.1.0 (Ralph-2 / M-1) — State C returns via `.error(...)` to
            // match `track.select`'s State C envelope. Previously this was
            // `.success(...)` which masked isError:false on the MCP wire and
            // broke clients switching on envelope-level error state.
            // #222 — a failed finder-column navigation can leave the panel
            // closed/drilled, so before returning we re-stage it to a
            // known-open baseline. This makes the failure NON-CASCADING: the
            // next set_instrument starts from an open panel instead of a
            // `library_panel_unavailable` inherited from this attempt. The
            // returned error stays the deterministic `ax_write_failed` (the
            // path genuinely did not resolve); the side effect is the no-drift
            // guarantee, surfaced via `panel_open_after_failure`.
            let restaged = await Self.restageLibraryPanelAfterFailure(staging: staging, runtime: runtime)
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Library path not fully resolvable: \(resolvedPath)",
                extras: setInstrumentBaseExtras(
                    requestedPath: resolvedPath,
                    category: category,
                    preset: preset,
                    targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                    targetTrackName: targetTrackName
                ).merging([
                    "precondition": "library_nav_failed",
                    "panel_open_after_failure": restaged.panelOpen,
                    "panel_restaged_after_failure": restaged.reopened,
                ]) { _, new in new }
            ))
        }
        try? await Task.sleep(nanoseconds: 800_000_000) // let Logic load the instrument

        // v3.1.0 (T2) — Honest Contract read-back. The Library Panel's
        // AXList reports the currently-selected preset via its
        // `AXSelectedChildren` attribute. When present and matching, we
        // return State A (verified:true). When present but different, State
        // B with `readback_mismatch`. When not exposed at all (Logic build
        // dependent), State B with `readback_unavailable`.
        let observed = AccessibilityChannel.readBackLibraryPreset(runtime: runtime)
        var base = setInstrumentBaseExtras(
            requestedPath: resolvedPath,
            category: category,
            preset: preset,
            targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
            targetTrackName: targetTrackName
        )
        base["observed"] = observed ?? NSNull()
        base["observed_patch_name"] = observed ?? NSNull()
        base["verify_source"] = "library_selected_children"
        if requestedTrackIndex != nil {
            base["target_track_selection_verified"] = true
            base["target_track_selection_reason"] = "verified"
            base["target_track_selection_observed_index"] = targetTrackIndex as Any? ?? NSNull()
            base["target_track_selection_verify_source"] = "ax_selected"
        }
        if let observed {
            if observed == preset {
                return .success(HonestContract.encodeStateA(
                    extras: base.merging(["readback_state": "verified"]) { _, new in new }
                ))
            }
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: base.merging([
                    "readback_state": HonestContract.UncertainReason.readbackMismatch.rawValue
                ]) { _, new in new }
            ))
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: base.merging([
                "readback_state": HonestContract.UncertainReason.readbackUnavailable.rawValue
            ]) { _, new in new }
        ))
    }

    /// #222 — after a failed `set_instrument` navigation, leave the Library
    /// panel in a known-open baseline so the failure does not cascade into the
    /// next attempt (the reported symptom: a later `set_instrument` reported
    /// `library_panel_unavailable` because a prior failed nav left the panel
    /// closed/wedged). The Library key command is a TOGGLE, so we re-open ONLY when the panel is
    /// actually closed — never re-toggle an already-open panel shut. Returns
    /// the observed post-failure panel state for the response diagnostics.
    private static func restageLibraryPanelAfterFailure(
        staging: LibraryPanelStaging,
        runtime: AXLogicProElements.Runtime
    ) async -> (panelOpen: Bool, reopened: Bool) {
        if staging.isPanelOpen(runtime) {
            return (panelOpen: true, reopened: false)
        }
        await staging.openPanel(runtime)
        try? await Task.sleep(nanoseconds: 400_000_000) // panel slide-in settle
        return (panelOpen: staging.isPanelOpen(runtime), reopened: true)
    }

    private static func setInstrumentBaseExtras(
        requestedPath: String,
        category: String,
        preset: String,
        targetTrackIndex: Any,
        targetTrackName: Any
    ) -> [String: Any] {
        [
            "requested": preset,
            "requested_patch_name": preset,
            "requested_category": category,
            "requested_path": requestedPath,
            "category": category,
            "preset": preset,
            "path": requestedPath,
            "target_track_index": targetTrackIndex,
            "target_track_name": targetTrackName
        ]
    }

    private static func selectedTrackIdentity(
        runtime: AXLogicProElements.Runtime
    ) -> (index: Int, name: String?)? {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        for (index, header) in headers.enumerated() {
            guard AXValueExtractors.extractSelectedState(header, runtime: runtime.ax) == true else {
                continue
            }
            let state = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
            let trimmed = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (index, trimmed.isEmpty ? nil : trimmed)
        }
        return nil
    }

}
