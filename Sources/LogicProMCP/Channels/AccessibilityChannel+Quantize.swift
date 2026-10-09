import ApplicationServices
import Foundation

// The inspector carries the requested grid; Q and the MIDI command do not. A matching inspector
// value certifies a write only while the independently read selection and retained AX target hold.
extension AccessibilityChannel {
    struct QuantizeTiming: Sendable {
        var menuOpenTimeoutMs = 1_500
        var menuCloseTimeoutMs = 1_000
        var readbackTimeoutMs = 1_500
        var pollIntervalMs = 80
        static let live = QuantizeTiming()
        static let immediate = QuantizeTiming(
            menuOpenTimeoutMs: 0, menuCloseTimeoutMs: 0, readbackTimeoutMs: 0, pollIntervalMs: 0)
    }

    private struct QuantizeReadFailure: Error {
        let reason: String
        let stage: String
        let status: String
    }

    private struct QuantizeTarget {
        let window: AXUIElement
        let content: AXUIElement
        let selectionAreas: [AXUIElement]
        let areas: [AXUIElement]
        let row: AXUIElement
        let mode: AXUIElement
        let value: AXUIElement
        let headers: [AXUIElement]
        let regions: [AXUIElement]
        let selected: [AXUIElement]

        func matches(_ other: QuantizeTarget) -> Bool {
            CFEqual(window, other.window) && CFEqual(content, other.content)
                && AccessibilityChannel.quantizeSameSet(selectionAreas, other.selectionAreas)
                && CFEqual(row, other.row)
                && CFEqual(mode, other.mode) && CFEqual(value, other.value)
                && AccessibilityChannel.quantizeSameSet(areas, other.areas)
                && AccessibilityChannel.quantizeSameSet(headers, other.headers)
                && AccessibilityChannel.quantizeSameSet(regions, other.regions)
                && AccessibilityChannel.quantizeSameSet(selected, other.selected)
        }
    }

    static func quantizeSelectedRegions(
        params: [String: String], runtime: AXLogicProElements.Runtime = .production,
        timing: QuantizeTiming = .live,
        popupCleaner: PluginPopupMenuCleaner? = nil
    ) async -> ChannelResult {
        let grid = params["value"] ?? params["grid"] ?? ""
        var extras: [String: Any] = ["operation": "edit.quantize", "grid": grid, "method": "region_inspector"]
        var written = false
        var cleanupNeeded = false
        var ownedPopup: AXUIElement?
        var ownedMenu: AXUIElement?
        func refusal(_ error: HonestContract.FailureError, _ reason: String) -> ChannelResult {
            extras["quantize_refusal"] = reason
            extras["write_attempted"] = written
            extras["safe_to_retry"] = !written
            return .error(HonestContract.encodeStateC(
                error: error, hint: "The retained Region inspector target could not be certified (\(reason)).", extras: extras))
        }
        func cleanup() -> Bool {
            cleanupNeeded = false
            // A global Logic-menu cleaner could cancel a menu the user opened after our baseline.
            // Retain the unique newly observed menu; never guess a target or post global Escape.
            guard let popup = ownedPopup, let menu = ownedMenu else {
                extras["popup"] = "ownership_unavailable"; return false
            }
            do {
                let menus = try quantizeMenus(popup, runtime.ax)
                guard menus.isEmpty || (menus.count == 1 && CFEqual(menus[0], menu)) else {
                    extras["popup"] = "ownership_changed"; return false
                }
                var clean = true
                if let popupCleaner {
                    // Explicit fake seam: even its clean result cannot replace the independent
                    // own-menu absence and global CG observations below.
                    let outcome = popupCleaner(runtime)
                    extras["popup"] = quantizeCloseState(outcome)
                    clean = outcome.isClean
                } else if !menus.isEmpty {
                    guard case .success(let actions) = AXHelpers.getActionNamesResult(menu, runtime: runtime.ax),
                          actions.contains(kAXCancelAction as String) else {
                        extras["popup"] = "still_open"; return false
                    }
                    let stillAttached = try quantizeMenus(popup, runtime.ax)
                    guard stillAttached.count == 1, CFEqual(stillAttached[0], menu) else {
                        extras["popup"] = "ownership_changed"; return false
                    }
                    extras["popup_cancel_returned"] = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime.ax)
                    extras["popup"] = "dismissed"
                } else { extras["popup"] = "closed" }
                guard try quantizeMenus(popup, runtime.ax).isEmpty else {
                    extras["popup"] = "still_open"; return false
                }
                guard let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList() else {
                    extras["popup"] = "unread"; return false
                }
                guard LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 else {
                    extras["popup"] = "still_open"; return false
                }
                return clean
            } catch { extras["popup"] = "unread"; return false }
        }
        guard let label = AXLocalePolicy.quantizeGridLabels[grid] else {
            return refusal(.invalidParams, "unsupported_grid")
        }
        guard !Task.isCancelled else { return refusal(.readbackUnavailable, "cancelled") }
        do {
            let target = try quantizeTarget(runtime)
            extras["regions_selected"] = target.selected.count
            extras["selection_source"] = "AXSelectedChildren_and_complete_region_census"
            guard !target.selected.isEmpty else { return refusal(.elementNotFound, "selection_empty") }
            let before = try quantizeString(target.value, kAXValueAttribute as String, runtime.ax, stage: "before")
            guard let before, !before.isEmpty else { return refusal(.readbackUnavailable, "before_unavailable") }
            extras["before"] = before
            guard try quantizeMenus(target.value, runtime.ax).isEmpty,
                  let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList(),
                  LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 else {
                return refusal(.readbackUnavailable, "preexisting_or_unread_popup")
            }
            guard try target.matches(quantizeTarget(runtime)) else {
                return refusal(.readbackUnavailable, "target_changed")
            }
            if label.matches(before, mode: .exact) {
                guard !Task.isCancelled else { return refusal(.readbackUnavailable, "cancelled") }
                guard try quantizeString(target.value, kAXValueAttribute as String, runtime.ax, stage: "unchanged") == before,
                      try target.matches(quantizeTarget(runtime)) else {
                    return refusal(.readbackUnavailable, "target_changed")
                }
                guard quantizePopupAbsenceCertified(target.value, runtime) else {
                    return refusal(.readbackUnavailable, "popup_cleanup_unconfirmed")
                }
                guard !Task.isCancelled else { return refusal(.readbackUnavailable, "cancelled") }
                extras["after"] = before; extras["changed"] = false
                extras["verify_source"] = "region_inspector_quantize_value"
                extras["write_attempted"] = false
                return .success(HonestContract.encodeStateA(extras: extras))
            }
            guard try quantizeBool(target.value, kAXEnabledAttribute as String, runtime.ax, stage: "popup_enabled") else {
                return refusal(.elementNotFound, "popup_disabled")
            }
            guard !Task.isCancelled else { return refusal(.readbackUnavailable, "cancelled") }
            written = true; cleanupNeeded = true
            ownedPopup = target.value
            // Logic can answer AXPress with cannotComplete even when the menu opens. Observe the
            // new menu, not the action's return code, and retain that exact menu for the leaf.
            extras["popup_press_returned"] = AXHelpers.performAction(target.value, kAXPressAction as String, runtime: runtime.ax)
            var menus: [AXUIElement] = []
            let openDeadline = Date().addingTimeInterval(Double(timing.menuOpenTimeoutMs) / 1000)
            repeat {
                menus = try quantizeMenus(target.value, runtime.ax)
                if !menus.isEmpty || Task.isCancelled { break }
                await quantizePause(timing)
            } while Date() < openDeadline
            extras["menus_opened"] = menus.count
            if Task.isCancelled {
                if menus.count == 1 { ownedMenu = menus[0] }
                _ = cleanup()
                return refusal(.readbackUnavailable, "cancelled")
            }
            guard menus.count == 1, let menu = menus.first else {
                _ = cleanup(); return refusal(.elementNotFound, "menu_unavailable")
            }
            ownedMenu = menu
            let items = try quantizeMenuItems(menu, label: label, ax: runtime.ax)
            extras["matching_items"] = items.count
            guard items.count == 1, let item = items.first else {
                _ = cleanup(); return refusal(.elementNotFound, "grid_item_unavailable")
            }
            // Re-read rather than rebind: a same-count replacement is still a different target.
            do {
                guard try target.matches(quantizeTarget(runtime)) else {
                    _ = cleanup(); return refusal(.readbackUnavailable, "target_changed")
                }
            } catch let failure as QuantizeReadFailure {
                extras["read_stage"] = failure.stage
                extras["read_status"] = failure.status
                _ = cleanup(); return refusal(.readbackUnavailable, "target_changed")
            } catch {
                _ = cleanup(); return refusal(.readbackUnavailable, "target_changed")
            }
            let retainedMenus = try quantizeMenus(target.value, runtime.ax)
            let retainedItems = try quantizeMenuItems(menu, label: label, ax: runtime.ax)
            guard retainedMenus.count == 1, CFEqual(retainedMenus[0], menu),
                  retainedItems.count == 1, CFEqual(retainedItems[0], item),
                  try quantizeBool(item, kAXEnabledAttribute as String, runtime.ax, stage: "item_enabled") else {
                _ = cleanup(); return refusal(.elementNotFound, "grid_item_changed_or_disabled")
            }
            guard !Task.isCancelled else {
                _ = cleanup(); return refusal(.readbackUnavailable, "cancelled")
            }
            extras["item_press_returned"] = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
            let closeDeadline = Date().addingTimeInterval(Double(timing.menuCloseTimeoutMs) / 1000)
            repeat {
                if Task.isCancelled { break }
                if try quantizeMenus(target.value, runtime.ax).isEmpty,
                   let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList(),
                   LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 { break }
                await quantizePause(timing)
            } while Date() < closeDeadline
            let clean = cleanup()
            guard !Task.isCancelled else { return refusal(.readbackUnavailable, "cancelled") }
            guard clean, try quantizeMenus(target.value, runtime.ax).isEmpty else {
                return refusal(.readbackUnavailable, "popup_cleanup_unconfirmed")
            }
            let readbackDeadline = Date().addingTimeInterval(Double(timing.readbackTimeoutMs) / 1000)
            repeat {
                guard !Task.isCancelled else { return refusal(.readbackUnavailable, "cancelled") }
                do {
                    guard try target.matches(quantizeTarget(runtime)) else {
                        return refusal(.readbackUnavailable, "target_changed")
                    }
                } catch { return refusal(.readbackUnavailable, "target_changed") }
                let after = try quantizeString(target.value, kAXValueAttribute as String, runtime.ax, stage: "after")
                extras["after"] = after ?? NSNull()
                if label.matches(after, mode: .exact) {
                    do {
                        guard try target.matches(quantizeTarget(runtime)) else {
                            return refusal(.readbackUnavailable, "target_changed")
                        }
                    } catch { return refusal(.readbackUnavailable, "target_changed") }
                    guard quantizePopupAbsenceCertified(target.value, runtime) else {
                        return refusal(.readbackUnavailable, "popup_cleanup_unconfirmed")
                    }
                    guard !Task.isCancelled else { return refusal(.readbackUnavailable, "cancelled") }
                    extras["changed"] = true; extras["write_attempted"] = true
                    extras["verify_source"] = "region_inspector_quantize_value"
                    return .success(HonestContract.encodeStateA(extras: extras))
                }
                await quantizePause(timing)
            } while Date() < readbackDeadline
            return refusal(.readbackMismatch, "grid_readback_mismatch")
        } catch let failure as QuantizeReadFailure {
            if cleanupNeeded { _ = cleanup() }
            extras["read_stage"] = failure.stage; extras["read_status"] = failure.status
            return refusal(.readbackUnavailable, failure.reason)
        } catch {
            if cleanupNeeded { _ = cleanup() }
            return refusal(.readbackUnavailable, "inventory_unavailable")
        }
    }

    private static func quantizeTarget(_ runtime: AXLogicProElements.Runtime) throws -> QuantizeTarget {
        let ax = runtime.ax
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { throw quantizeFailure("app") }
        let windows = try quantizeElements(app, kAXWindowsAttribute as String, ax, stage: "windows")
        guard let raw = try quantizeRaw(app, kAXMainWindowAttribute as String, ax, stage: "main_window"),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw quantizeFailure("main_window") }
        let window = unsafeDowncast(raw, to: AXUIElement.self)
        guard windows.contains(where: { CFEqual($0, window) }),
              try quantizeString(window, kAXRoleAttribute as String, ax, stage: "window_role") == kAXWindowRole as String else {
            throw quantizeFailure("main_window")
        }
        let subrole = try quantizeString(window, kAXSubroleAttribute as String, ax, stage: "window_subrole")
        guard subrole != kAXDialogSubrole as String, subrole != kAXSystemDialogSubrole as String else {
            throw quantizeFailure("main_window")
        }
        let nodes = try quantizeWalk(window, ax)
        let contents = try nodes.filter {
            try quantizeString($0, kAXRoleAttribute as String, ax, stage: "content_role") == kAXGroupRole as String
                && AXLocalePolicy.trackContentExplicit.containsNormalized(
                try quantizeString($0, kAXDescriptionAttribute as String, ax, stage: "content_description") ?? "")
        }
        guard contents.count == 1, let content = contents.first else { throw quantizeFailure("track_content") }
        let contentNodes = try quantizeWalk(content, ax)
        let areas = try contentNodes.filter {
            try quantizeString($0, kAXRoleAttribute as String, ax, stage: "area_role") == "AXLayoutArea"
        }
        // Logic can publish disjoint track-background areas, or nest them under an
        // arrangement area. Read every outermost area's aggregate; never pick one track.
        let areaCensuses = try areas.map { (area: $0, nodes: try quantizeWalk($0, ax)) }
        let owners = areaCensuses.filter { census in
            !areaCensuses.contains { other in
                !CFEqual(other.area, census.area)
                    && other.nodes.contains { CFEqual($0, census.area) }
            }
        }
        guard !owners.isEmpty else {
            throw quantizeFailure("selection_area", status: "candidate_count_\(areas.count)")
        }
        var regions: [AXUIElement] = [], selected: [AXUIElement] = []
        for node in contentNodes {
            if try quantizeString(node, kAXRoleAttribute as String, ax, stage: "region_role") == kAXLayoutItemRole as String {
                guard owners.filter({ owner in owner.nodes.contains { CFEqual($0, node) } }).count == 1 else {
                    throw quantizeFailure("region_owner")
                }
                let help = try quantizeString(node, kAXHelpAttribute as String, ax, stage: "region_help")
                guard AXLocalePolicy.regionHelpKeyword.containsAny(in: help ?? "") else { throw quantizeFailure("region_help") }
                regions.append(node)
                if try quantizeBool(node, kAXSelectedAttribute as String, ax, stage: "region_selected") { selected.append(node) }
            }
        }
        // The viewport census alone cannot prove that offscreen selected regions are absent. Require
        // AX's independently readable aggregate and exact CF membership, never a count-only fallback.
        for owner in owners {
            let aggregate = try quantizeElements(owner.area, kAXSelectedChildrenAttribute as String, ax, stage: "selected_children")
            let selectedInArea = selected.filter { region in owner.nodes.contains { CFEqual($0, region) } }
            guard quantizeSameSet(aggregate, selectedInArea) else { throw quantizeFailure("selected_children") }
        }
        let headers: [AXUIElement]
        switch AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime) {
        case .read(let read) where !read.isEmpty: headers = read
        case .unreadable(let stage, let status): throw QuantizeReadFailure(reason: "inventory_unavailable", stage: stage, status: status)
        default: throw quantizeFailure("track_headers")
        }
        let frame = try quantizeFrame(window, ax)
        for element in headers + regions {
            guard frame.contains(try quantizeFrame(element, ax)) else { throw quantizeFailure("outside_arrangement") }
        }
        var rows: [(AXUIElement, AXUIElement, AXUIElement)] = []
        for node in nodes {
            guard try quantizeString(node, kAXRoleAttribute as String, ax, stage: "row_role") == kAXRowRole as String else { continue }
            let children = try quantizeChildren(node, ax)
            let popups = try children.filter {
                try quantizeString($0, kAXRoleAttribute as String, ax, stage: "popup_role") == kAXPopUpButtonRole as String
            }
            let modes = try popups.filter {
                AXLocalePolicy.quantizeModePopupValue.matches(
                    try quantizeString($0, kAXValueAttribute as String, ax, stage: "popup_value"), mode: .exact)
            }
            if modes.count == 1, popups.count == 2 {
                let mode = modes[0]
                rows.append((node, mode, popups.first { !CFEqual($0, mode) }!))
            } else if !modes.isEmpty { throw quantizeFailure("quantize_row") }
        }
        guard rows.count == 1, let row = rows.first else { throw quantizeFailure("quantize_row") }
        return QuantizeTarget(window: window, content: content, selectionAreas: owners.map(\.area), areas: areas, row: row.0,
                              mode: row.1, value: row.2, headers: headers, regions: regions, selected: selected)
    }

    private static func quantizeFailure(_ stage: String, status: String = "unavailable") -> QuantizeReadFailure {
        QuantizeReadFailure(reason: stage == "selected_children" ? "selection_children_unavailable" : "inventory_unavailable",
                            stage: stage, status: status)
    }

    private static func quantizeRaw(_ element: AXUIElement, _ attribute: String, _ ax: AXHelpers.Runtime,
                                    stage: String) throws -> AnyObject? {
        let read: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(element, attribute, runtime: ax)
        switch read {
        case .success(let value): return value
        case .failure(let error):
            if error.isDefinitiveAbsence { return nil }
            throw quantizeFailure(stage, status: error.diagnosticLabel)
        }
    }

    private static func quantizeString(_ element: AXUIElement, _ attribute: String, _ ax: AXHelpers.Runtime,
                                       stage: String) throws -> String? {
        guard let raw = try quantizeRaw(element, attribute, ax, stage: stage) else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID(), let value = raw as? String else {
            throw quantizeFailure(stage, status: "malformed")
        }
        return value
    }

    private static func quantizeBool(_ element: AXUIElement, _ attribute: String, _ ax: AXHelpers.Runtime,
                                     stage: String) throws -> Bool {
        guard let raw = try quantizeRaw(element, attribute, ax, stage: stage),
              CFGetTypeID(raw) == CFBooleanGetTypeID(), let value = raw as? Bool else {
            throw quantizeFailure(stage, status: "malformed_or_absent")
        }
        return value
    }

    private static func quantizeElements(_ element: AXUIElement, _ attribute: String, _ ax: AXHelpers.Runtime,
                                         stage: String) throws -> [AXUIElement] {
        guard let raw = try quantizeRaw(element, attribute, ax, stage: stage),
              CFGetTypeID(raw) == CFArrayGetTypeID() else { throw quantizeFailure(stage, status: "malformed_or_absent") }
        let array = unsafeDowncast(raw, to: CFArray.self)
        var elements: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { throw quantizeFailure(stage, status: "malformed") }
            let member = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(member) == AXUIElementGetTypeID() else { throw quantizeFailure(stage, status: "malformed") }
            let element = unsafeDowncast(member, to: AXUIElement.self)
            guard !elements.contains(where: { CFEqual($0, element) }) else { throw quantizeFailure(stage, status: "duplicate") }
            elements.append(element)
        }
        return elements
    }

    private static func quantizeChildren(_ element: AXUIElement, _ ax: AXHelpers.Runtime) throws -> [AXUIElement] {
        switch AXHelpers.childrenResult(element, runtime: ax) {
        case .success(let children): return children
        case .failure(let error):
            if error.isDefinitiveAbsence { return [] }
            throw quantizeFailure("children", status: error.diagnosticLabel)
        }
    }

    private static func quantizeWalk(_ root: AXUIElement, _ ax: AXHelpers.Runtime) throws -> [AXUIElement] {
        var nodes: [AXUIElement] = []
        func walk(_ node: AXUIElement, _ depth: Int) throws {
            guard depth <= 32 else { throw quantizeFailure("census_bound") }
            guard let role = try quantizeString(node, kAXRoleAttribute as String, ax, stage: "role") else { throw quantizeFailure("role") }
            // Menus can alias their AX children. They are not arrangement authority;
            // the retained popup's unique menu and grid leaf are verified separately.
            if role == kAXMenuRole as String { return }
            guard !nodes.contains(where: { CFEqual($0, node) }) else { throw quantizeFailure("census_bound") }
            nodes.append(node)
            // Text-field editor children are not arrangement/inspector authority; their lazy AX
            // children are not used to infer a complete region set or discover a quantize row.
            if role == kAXTextFieldRole as String { return }
            for child in try quantizeChildren(node, ax) { try walk(child, depth + 1) }
        }
        try walk(root, 0)
        return nodes
    }

    private static func quantizeFrame(_ element: AXUIElement, _ ax: AXHelpers.Runtime) throws -> CGRect {
        guard let position = try quantizeRaw(element, kAXPositionAttribute as String, ax, stage: "position"),
              let size = try quantizeRaw(element, kAXSizeAttribute as String, ax, stage: "size"),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { throw quantizeFailure("frame") }
        let p = unsafeDowncast(position, to: AXValue.self), s = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
              AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { throw quantizeFailure("frame", status: "malformed") }
        return CGRect(origin: point, size: dimensions)
    }

    private static func quantizeSameSet(_ a: [AXUIElement], _ b: [AXUIElement]) -> Bool {
        a.count == b.count && a.allSatisfy { element in b.contains { CFEqual(element, $0) } }
    }

    private static func quantizeMenus(_ popup: AXUIElement, _ ax: AXHelpers.Runtime) throws -> [AXUIElement] {
        try quantizeChildren(popup, ax).filter {
            guard let role = try quantizeString($0, kAXRoleAttribute as String, ax, stage: "menu_role") else { throw quantizeFailure("menu_role") }
            return role == kAXMenuRole as String
        }
    }

    private static func quantizeMenuItems(_ menu: AXUIElement, label: AXLocalePolicy.LabelSet,
                                         ax: AXHelpers.Runtime) throws -> [AXUIElement] {
        var matches: [AXUIElement] = []
        for item in try quantizeChildren(menu, ax) {
            guard let role = try quantizeString(item, kAXRoleAttribute as String, ax, stage: "item_role") else { throw quantizeFailure("item_role") }
            guard role == kAXMenuItemRole as String else { continue }
            guard let title = try quantizeString(item, kAXTitleAttribute as String, ax, stage: "item_title") else { throw quantizeFailure("item_title") }
            if label.matches(title, mode: .exact) { matches.append(item) }
        }
        return matches
    }

    private static func quantizePause(_ timing: QuantizeTiming) async {
        if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
    }

    // A later popup cannot inherit the earlier cleanup certificate. This is a final fresh
    // observation, not an atomic lock on Logic or permission to dismiss a different menu.
    private static func quantizePopupAbsenceCertified(_ popup: AXUIElement, _ runtime: AXLogicProElements.Runtime) -> Bool {
        do {
            guard try quantizeMenus(popup, runtime.ax).isEmpty,
                  let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList() else { return false }
            return LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0
        } catch { return false }
    }

    private static func quantizeCloseState(_ outcome: PluginPopupMenuCleanupOutcome) -> String {
        switch outcome {
        case .noPopupObserved: return "closed"
        case .dismissed: return "dismissed"
        case .popupCountUnavailable: return "unread"
        case .couldNotDismiss: return "still_open"
        }
    }
}
