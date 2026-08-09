import ApplicationServices
import AppKit
import Foundation

/// Project/document surface: project info, Save As via AX dialog, and marker reads.
extension AccessibilityChannel {
    // MARK: - Creator Studio New Project chooser

    static func chooserSelectionIsUnambiguous(
        windowTitle: String?,
        emptyProjectLabelCount: Int,
        chooseButtonCount: Int,
        chooseEnabled: Bool
    ) -> Bool {
        windowTitle == "Choose a Project"
            && emptyProjectLabelCount == 1
            && chooseButtonCount == 1
            && chooseEnabled
    }

    static func createEmptyProjectFromChooser(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .error("Creator Studio project chooser is not visible")
        }
        let windowTitle = AXHelpers.getTitle(window, runtime: runtime.ax)
        let emptyProjectLabels = AXHelpers.findAllDescendants(
            of: window, role: kAXStaticTextRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter { AXHelpers.getTitle($0, runtime: runtime.ax) == "Empty Project" }
        let chooseButtons = AXHelpers.findAllDescendants(
            of: window, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter { AXHelpers.getTitle($0, runtime: runtime.ax) == "Choose" }
        let chooseEnabled: Bool = chooseButtons.first.flatMap {
            AXHelpers.getAttribute($0, kAXEnabledAttribute as String, runtime: runtime.ax)
        } ?? false

        guard chooserSelectionIsUnambiguous(
            windowTitle: windowTitle,
            emptyProjectLabelCount: emptyProjectLabels.count,
            chooseButtonCount: chooseButtons.count,
            chooseEnabled: chooseEnabled
        ), let chooseButton = chooseButtons.first else {
            return .error("Creator Studio chooser is not the exact enabled Empty Project selection")
        }
        guard AXHelpers.performAction(chooseButton, kAXPressAction as String, runtime: runtime.ax) else {
            return .error("Failed to press the exact Creator Studio Choose button")
        }

        // Empty Project opens Logic's mandatory New Track sheet. Reuse the
        // existing structural classifier: it only clicks Create when the sheet
        // is identified as mandatoryNewTrack; unknown sheets fail closed.
        var createdTrack = false
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let outcome = await reconcileAfterMutation(isDeleteContext: false, runtime: runtime)
            switch outcome.kind {
            case .mandatoryNewTrack:
                guard outcome.performed else {
                    return .error("Mandatory New Track sheet was identified but Create was not performed")
                }
                createdTrack = true
            case .unknownSheet, .deleteConfirm:
                return .error("Unexpected blocking sheet after choosing Empty Project")
            case .none, .informationalAlert, .strayMenu:
                break
            }
            if createdTrack,
               let current = AXLogicProElements.mainWindow(runtime: runtime),
               AXHelpers.getTitle(current, runtime: runtime.ax) != "Choose a Project" {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "operation": "project.new",
                        "method": "accessibility",
                        "selection": "Empty Project",
                        "mandatory_track_created": true,
                    ]
                ))
            }
        }
        return .error("Creator Studio did not expose a created Project after the exact chooser action")
    }

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

    static func openBounceDialogViaMenu(
        systemEventsAuthorized: @Sendable () -> Bool = { PermissionChecker.checkSystemEventsAutomation() },
        executeScript: @escaping @Sendable (String) async -> ChannelResult = {
            await AppleScriptChannel.executeAppleScript($0)
        }
    ) async -> ChannelResult {
        guard systemEventsAuthorized() else {
            return .error(HonestContract.encodeStateC(
                error: .systemEventsAutomationDenied,
                hint: AppleScriptErrorClassifier.systemEventsAutomationDeniedHint,
                extras: [
                    "operation": "project.bounce",
                    "failure_stage": "preflight_system_events_permission",
                    "write_attempted": false,
                    "safe_to_retry": false,
                ]
            ))
        }

        let processTarget = LogicProTarget.appleScriptTarget().systemEventsProcessTarget
        let script = """
        tell application "System Events"
            tell \(processTarget)
                set frontmost to true
                set menuClicked to false
                repeat with targetName in {"프로젝트 또는 섹션…", "프로젝트 또는 섹션...", "Project or Section…", "Project or Section..."}
                    if menuClicked is false then
                        try
                            click menu item (targetName as text) of menu 1 of menu item "바운스" of menu 1 of menu bar item "파일" of menu bar 1
                            set menuClicked to true
                        on error
                            try
                                click menu item (targetName as text) of menu 1 of menu item "Bounce" of menu 1 of menu bar item "File" of menu bar 1
                                set menuClicked to true
                            end try
                        end try
                    end if
                end repeat
                if menuClicked is false then return "BOUNCE_MENU_ITEM_NOT_FOUND"
                repeat 10 times
                    set bounceName to ""
                    try
                        set bounceName to name of front window
                    end try
                    try
                        set bounceName to bounceName & " " & name of sheet 1 of front window
                    end try
                    if bounceName contains "Bounce" or bounceName contains "바운스" then
                        return "BOUNCE_DIALOG_OPENED"
                    end if
                    delay 0.2
                end repeat
                return "BOUNCE_DIALOG_NOT_FOUND"
            end tell
        end tell
        """

        let result = await executeScript(script)
        guard result.isSuccess else {
            if HonestContract.stateCErrorCode(result.message)
                == HonestContract.FailureError.systemEventsAutomationDenied.rawValue {
                return result
            }
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "File > Bounce menu execution failed",
                extras: [
                    "operation": "project.bounce",
                    "failure_stage": "open_bounce_menu",
                    "write_attempted": true,
                    "safe_to_retry": true,
                    "cause": result.message,
                ]
            ))
        }

        if result.message.contains("BOUNCE_DIALOG_OPENED") {
            return .success(HonestContract.encodeStateA(extras: [
                "operation": "project.bounce",
                "requested": "bounce_dialog_open",
                "observed": "bounce_dialog_open",
                "dialog_opened": true,
                "bounce_fired": false,
                "via": "file-menu",
                "next_action": "Review the Bounce settings in Logic, then confirm and choose the destination.",
            ]))
        }
        if result.message.contains("BOUNCE_MENU_ITEM_NOT_FOUND") {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "File > Bounce > Project or Section menu item was not found",
                extras: [
                    "operation": "project.bounce",
                    "failure_stage": "locate_bounce_menu_item",
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .dialogNotFound,
            hint: "File > Bounce menu was clicked but the Bounce dialog did not appear within 2 seconds",
            extras: [
                "operation": "project.bounce",
                "failure_stage": "verify_bounce_dialog",
                "write_attempted": true,
                "safe_to_retry": true,
            ]
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
    /// the same lookup.
    /// v3.1.9-final puts strategy ordering in `enumerateMarkers` and uses
    /// the in-window helper directly only when there is no arrangement
    /// area to pass.
    ///
    /// Behaviour matrix:
    ///
    /// | arrange area | marker list window | strategy |
    /// |--------------|--------------------|----------|
    /// | non-nil      | open / closed      | `enumerateMarkers(in: area)` runs all 3 strategies |
    static func defaultGetMarkers(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        if let listWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
            return encodeResult(AXLogicProElements.enumerateMarkersFromListWindow(
                listWindow, runtime: runtime.ax
            ))
        }
        if let area = AXLogicProElements.getArrangementArea(runtime: runtime) {
            let legacyMarkers = AXLogicProElements.enumerateMarkers(in: area, runtime: runtime)
            if !legacyMarkers.isEmpty {
                return encodeResult(legacyMarkers)
            }
        }
        return .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "Open Navigate > Open Marker List so Logic Pro can expose marker rows to Accessibility.",
            extras: ["reason": "marker_list_not_open"]
        ))
    }

}
