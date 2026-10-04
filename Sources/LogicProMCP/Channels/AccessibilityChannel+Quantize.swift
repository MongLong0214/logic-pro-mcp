import ApplicationServices
import Foundation

// #1094: `edit.quantize` through the Region inspector, the one path measured to carry the grid.
// Apple's Q and the MIDI key command apply whatever quantize value Logic already holds. The
// inspector's Quantize row holds a mode pop-up (value: Logic's `Quantize`) and, to its right, a value
// pop-up whose menu offers the grids by Logic's own labels (lpm-evidence/1094/explore2-ko.json). The
// value pop-up applies to every selected region; its own value is the readback.
extension AccessibilityChannel {
    struct QuantizeTiming: Sendable {
        var menuOpenTimeoutMs = 1_500
        var menuCloseTimeoutMs = 1_000
        var readbackTimeoutMs = 1_500
        var pollIntervalMs = 80

        static let live = QuantizeTiming()
        static let immediate = QuantizeTiming(
            menuOpenTimeoutMs: 0, menuCloseTimeoutMs: 0, readbackTimeoutMs: 0, pollIntervalMs: 0
        )
    }

    /// The regions selected when the call starts; nil when the selection did not read.
    typealias QuantizeSelectionReader = @Sendable (AXLogicProElements.Runtime) -> [RegionInfo]?

    static let liveQuantizeSelectionReader: QuantizeSelectionReader = { runtime in
        selectedRegionInfos(runtime: runtime)
    }

    static func quantizeSelectedRegions(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        timing: QuantizeTiming = .live,
        selection: QuantizeSelectionReader = liveQuantizeSelectionReader,
        popupCleaner: PluginPopupMenuCleaner = livePluginPopupMenuCleaner
    ) async -> ChannelResult {
        let operation = "edit.quantize"
        let grid = params["value"] ?? params["grid"] ?? ""
        var extras: [String: Any] = ["operation": operation, "grid": grid, "method": "region_inspector"]

        func refusal(_ error: HonestContract.FailureError, _ hint: String, written: Bool = false) -> ChannelResult {
            extras["write_attempted"] = written
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: extras))
        }

        guard let label = AXLocalePolicy.quantizeGridLabels[grid] else {
            return refusal(.invalidParams, "The Region inspector offers no grid for '\(grid)'; nothing was pressed.")
        }
        // The inspector edits the selected regions, and with none selected it edits the defaults for new
        // regions instead, so an empty or unread selection is refused before anything is pressed.
        guard let selected = selection(runtime) else {
            return refusal(.readbackUnavailable, "The region selection did not read; nothing was pressed.")
        }
        guard !selected.isEmpty else {
            return refusal(.elementNotFound, "No region is selected. Select the regions to quantize; nothing was pressed.")
        }
        extras["regions_selected"] = selected.count

        let rows = quantizeRows(runtime: runtime.ax, in: runtime)
        guard rows.count == 1, let row = rows.first else {
            extras["quantize_rows_found"] = rows.count
            return refusal(.elementNotFound, rows.isEmpty
                ? "The Region inspector's Quantize row is not on screen (show the inspector); nothing was pressed."
                : "More than one Quantize row is on screen, so none is pressed.")
        }
        guard let valuePopup = row.valuePopup else {
            return refusal(.elementNotFound, "The Quantize row holds no single value pop-up beside its mode pop-up; nothing was pressed.")
        }

        let before = popupValue(valuePopup, runtime: runtime.ax)
        extras["before"] = before ?? NSNull()
        if label.matches(before, mode: .exact) {
            extras["after"] = before ?? NSNull()
            extras["changed"] = false
            extras["verify_source"] = "region_inspector_quantize_value"
            extras["write_attempted"] = false
            return .success(HonestContract.encodeStateA(extras: extras))
        }

        let menusBefore = popupMenus(of: valuePopup, runtime: runtime.ax)
        // The press's return code is not the answer: Logic's pop-ups answer AXPress with
        // kAXErrorCannotComplete (-25205) on presses that do open the menu. Gating on it refused
        // every call in the 2026-10-04 ten-language run (20 of 20, "did not take the press") while
        // the pop-up was there. The menu that opens is the answer.
        let pressed = AXHelpers.performAction(valuePopup, kAXPressAction as String, runtime: runtime.ax)
        extras["popup_press_returned"] = pressed
        let menus = await newPopupMenus(of: valuePopup, excluding: menusBefore, timing: timing, runtime: runtime.ax)
        guard menus.count == 1, let menu = menus.first else {
            extras["menus_opened"] = menus.count
            extras["popup"] = closeState(popupCleaner(runtime))
            return refusal(.elementNotFound, "The value pop-up opened no single menu; nothing was chosen.", written: true)
        }
        let items = AXHelpers.getChildren(menu, runtime: runtime.ax).filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == (kAXMenuItemRole as String)
                && label.matches(AXHelpers.getTitle($0, runtime: runtime.ax), mode: .exact)
        }
        guard items.count == 1, let item = items.first else {
            extras["matching_items"] = items.count
            extras["popup"] = closeState(popupCleaner(runtime))
            return refusal(.elementNotFound, "The value pop-up's menu offered no single item for '\(grid)'; nothing was chosen.",
                           written: true)
        }
        // As with the pop-up, the item's press return code is not the answer; the pop-up's value
        // read back after it is.
        extras["item_press_returned"] = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
        extras["popup"] = await waitForMenusToClose(runtime: runtime, timing: timing, cleaner: popupCleaner)

        // The pop-up's own value after the choice is the readback, not the press's return code.
        var after = popupValue(valuePopup, runtime: runtime.ax)
        let deadline = Date().addingTimeInterval(Double(timing.readbackTimeoutMs) / 1000.0)
        while !label.matches(after, mode: .exact) && Date() < deadline {
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
            after = popupValue(valuePopup, runtime: runtime.ax)
        }
        extras["after"] = after ?? NSNull()
        extras["write_attempted"] = true
        guard label.matches(after, mode: .exact) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackMismatch,
                hint: "The value pop-up does not show '\(grid)' after the choice.",
                extras: extras
            ))
        }
        extras["changed"] = true
        extras["verify_source"] = "region_inspector_quantize_value"
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    struct QuantizeRow {
        let mode: AXUIElement
        /// The row's one AXPopUpButton other than the mode pop-up, nil when there is not exactly one.
        let valuePopup: AXUIElement?
    }

    /// Every Quantize row in Logic's windows: an AXPopUpButton whose value is the `Quantize` row, with
    /// its parent's other pop-ups.
    static func quantizeRows(runtime ax: AXHelpers.Runtime, in runtime: AXLogicProElements.Runtime) -> [QuantizeRow] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: ax) ?? []
        var rows: [QuantizeRow] = []
        for window in windows {
            let modes = AXHelpers.findAllDescendants(
                of: window, role: kAXPopUpButtonRole as String, maxDepth: 14, runtime: ax
            ).filter {
                AXLocalePolicy.quantizeModePopupValue.matches(popupValue($0, runtime: ax), mode: .exact)
            }
            for mode in modes {
                let parent: AXUIElement? = AXHelpers.getAttribute(mode, kAXParentAttribute as String, runtime: ax)
                let others = parent.map { AXHelpers.getChildren($0, runtime: ax) }?.filter {
                    AXHelpers.getRole($0, runtime: ax) == (kAXPopUpButtonRole as String) && !CFEqual($0, mode)
                } ?? []
                rows.append(QuantizeRow(mode: mode, valuePopup: others.count == 1 ? others[0] : nil))
            }
        }
        return rows
    }

    private static func popupValue(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        AXHelpers.getValue(element, runtime: runtime) as? String
    }

    private static func popupMenus(of popup: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement] {
        AXHelpers.getChildren(popup, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
        }
    }

    private static func newPopupMenus(
        of popup: AXUIElement,
        excluding before: [AXUIElement],
        timing: QuantizeTiming,
        runtime: AXHelpers.Runtime
    ) async -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(Double(timing.menuOpenTimeoutMs) / 1000.0)
        repeat {
            let fresh = popupMenus(of: popup, runtime: runtime).filter { menu in
                !before.contains { CFEqual($0, menu) }
            }
            if !fresh.isEmpty { return fresh }
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
        } while Date() < deadline
        return []
    }

    /// After a choice the menu closes itself; Logic's pop-up windows are given `menuCloseTimeoutMs` to
    /// go before the shared cleanup has the last word, as the output pop-up does.
    private static func waitForMenusToClose(
        runtime: AXLogicProElements.Runtime,
        timing: QuantizeTiming,
        cleaner: PluginPopupMenuCleaner
    ) async -> String {
        let deadline = Date().addingTimeInterval(Double(timing.menuCloseTimeoutMs) / 1000.0)
        repeat {
            if let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList(),
               LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 {
                break
            }
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
        } while Date() < deadline
        return closeState(cleaner(runtime))
    }

    private static func closeState(_ outcome: PluginPopupMenuCleanupOutcome) -> String {
        switch outcome {
        case .noPopupObserved: return "closed"
        case .dismissed: return "dismissed"
        case .popupCountUnavailable: return "unread"
        case .couldNotDismiss: return "still_open"
        }
    }
}
