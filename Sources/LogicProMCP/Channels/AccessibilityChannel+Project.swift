import ApplicationServices
import AppKit
import Foundation

/// Project/document surface: project info, Save As via AX dialog, and marker reads.
extension AccessibilityChannel {
    // MARK: - Save As via AX Dialog

    static func saveAsViaAXDialog(
        path: String,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        // Validate path before setting it into the AX dialog
        guard AppleScriptSafety.isValidProjectPath(path, requireExisting: false) else {
            return .error("save_as requires an absolute .logicx project path")
        }

        // Step 1: Trigger Save As via menu click
        let koreanResult = clickMenuItem("다른 이름으로 저장…", menuName: "파일", runtime: runtime)
        let triggered = koreanResult.isSuccess
            || clickMenuItem("Save As…", menuName: "File", runtime: runtime).isSuccess

        guard triggered else {
            return .error("Failed to open Save As dialog via menu")
        }

        // Step 2: Wait for save dialog sheet to appear (up to 3s)
        var sheet: AXUIElement?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { continue }
            let children = AXHelpers.getChildren(window, runtime: runtime.ax)
            for child in children {
                let role = AXHelpers.getRole(child, runtime: runtime.ax)
                if role == "AXSheet" || role == "AXWindow" {
                    let descendants = AXHelpers.findAllDescendants(of: child, role: "AXTextField", runtime: runtime.ax)
                    if !descendants.isEmpty {
                        sheet = child
                        break
                    }
                }
            }
            if sheet != nil { break }
        }

        guard let saveSheet = sheet else {
            return .error("Save As dialog did not appear within 3 seconds")
        }

        // Helper: dismiss dialog on failure (press Escape to avoid blocking UI)
        func dismissDialog() {
            let cancelButtons = AXHelpers.findAllDescendants(of: saveSheet, role: "AXButton", runtime: runtime.ax)
            for btn in cancelButtons {
                if AXLocalePolicy.elementMatches(btn, AXLocalePolicy.cancelButton, runtime: runtime.ax) {
                    AXHelpers.performAction(btn, kAXPressAction, runtime: runtime.ax)
                    return
                }
            }
        }

        // Step 3: Find filename text field and set full path
        let textFields = AXHelpers.findAllDescendants(of: saveSheet, role: "AXTextField", runtime: runtime.ax)
        guard let filenameField = textFields.first else {
            dismissDialog()
            return .error("Cannot find filename field in Save As dialog")
        }

        AXHelpers.setAttribute(filenameField, kAXValueAttribute, path as CFTypeRef, runtime: runtime.ax)
        // Confirm the text entry so the save panel updates its internal path state
        AXHelpers.performAction(filenameField, kAXConfirmAction, runtime: runtime.ax)
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for panel to process

        // Step 4: Find and click Save button
        let buttons = AXHelpers.findAllDescendants(of: saveSheet, role: "AXButton", runtime: runtime.ax)
        var saveClicked = false
        for button in buttons {
            if AXLocalePolicy.elementMatches(button, AXLocalePolicy.saveConfirmationButton, runtime: runtime.ax) {
                AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax)
                saveClicked = true
                break
            }
        }

        guard saveClicked else {
            dismissDialog()
            return .error("Cannot find Save button in Save As dialog")
        }

        // Step 5: Verify file exists (up to 5s)
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if FileManager.default.fileExists(atPath: path) {
                return .success(HonestContract.encodeStateA(
                    extras: ["requested": path, "observed": path, "via": "save-dialog"]
                ))
            }
        }

        let pathWithExt = path.hasSuffix(".logicx") ? path : path + ".logicx"
        if FileManager.default.fileExists(atPath: pathWithExt) {
            return .success(HonestContract.encodeStateA(
                extras: ["requested": path, "observed": pathWithExt, "via": "save-dialog-with-ext"]
            ))
        }

        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "Save As dialog completed but no file appeared at requested path within 5s",
            extras: ["requested": path]
        ))
    }

    private static func clickMenuItem(
        _ itemTitle: String,
        menuName: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let item = AXLogicProElements.menuItem(path: [menuName, itemTitle], runtime: runtime) else {
            return .error("Cannot find menu item: \(menuName) > \(itemTitle)")
        }
        guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to click: \(menuName) > \(itemTitle)")
        }
        return .success("{\"menu_clicked\":\"\(itemTitle)\"}")
    }

    // MARK: - Project

    static func defaultGetProjectInfo(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window, runtime: runtime.ax) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - Markers

    /// v3.1.9 (Issue #8) — Logic 12.2 marker subtree path.
    ///
    /// Single delegating wrapper around `AXLogicProElements.enumerateMarkers`
    /// (when the arrangement area exists) or its in-window scrape helper
    /// (when 12.2 has dropped the arrangement-area identifier). Pre-v3.1.9
    /// this function did its own copy of the marker-list-window strategy
    /// AND then called `enumerateMarkers(in:)` which redundantly retried
    /// the same lookup — boomer review flagged the double scrape.
    /// v3.1.9-final puts strategy ordering in `enumerateMarkers` and uses
    /// the in-window helper directly only when there is no arrangement
    /// area to pass.
    ///
    /// Behaviour matrix:
    ///
    /// | arrange area | marker list window | strategy |
    /// |--------------|--------------------|----------|
    /// | non-nil      | open / closed      | `enumerateMarkers(in: area)` runs all 3 strategies |
    /// | nil (12.2)   | open               | `enumerateMarkersFromListWindow` direct |
    /// | nil          | closed             | empty (honest, cache stamped) |
    ///
    /// The "empty as success" return on the no-surface case is intentional:
    /// it lets `StatePoller` write `[]` into the cache so resource handlers
    /// report `source: "ax_live"` rather than `source: "default"` — telling
    /// callers the poll ran and observed nothing rather than the poll
    /// never having run.
    static func defaultGetMarkers(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        if let area = AXLogicProElements.getArrangementArea(runtime: runtime) {
            return encodeResult(AXLogicProElements.enumerateMarkers(in: area, runtime: runtime))
        }
        // Logic 12.2 commonly has no arrangement area identifier; fall
        // straight to the marker list window scrape without re-walking
        // strategies that require an arrange-area root.
        if let listWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
            return encodeResult(AXLogicProElements.enumerateMarkersFromListWindow(
                listWindow, runtime: runtime.ax
            ))
        }
        return encodeResult([MarkerState]())
    }

}
