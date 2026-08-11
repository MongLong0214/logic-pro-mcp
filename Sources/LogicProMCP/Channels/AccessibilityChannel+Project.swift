import ApplicationServices
import AppKit
import Foundation

/// Project/document surface: project info, Save As via AX dialog, and marker reads.
extension AccessibilityChannel {
    // MARK: - Creator Studio New Project chooser

    static func blankApplicationCanRevealChooser(windowCount: Int?) -> Bool {
        windowCount == 0
    }

    static func createEmptyProjectFromQualifiedState(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        if exactEmptyProjectChooserIsVisible(runtime: runtime) {
            return await createEmptyProjectFromChooser(runtime: runtime)
        }

        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .error("Logic Pro AX application root is unavailable")
        }
        let windows: [AXUIElement]? = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        )
        guard blankApplicationCanRevealChooser(windowCount: windows?.count) else {
            return .error("Creator Studio has a non-chooser window; refusing project.new")
        }

        let target = LogicProTarget.appleScriptTarget()
        let reveal = await runtime.executeAppleScript("""
        \(target.activateByBundleID)
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                if (count of windows) is not 0 then return "WINDOWS_PRESENT"
                if not (exists menu item "New" of menu 1 of menu bar item "File" of menu bar 1) then return "EXACT_NEW_NOT_FOUND"
                click menu item "New" of menu 1 of menu bar item "File" of menu bar 1
                return "EXACT_NEW_CLICKED"
            end tell
        end tell
        """)
        guard reveal.isSuccess, reveal.message.contains("EXACT_NEW_CLICKED") else {
            return .error("Could not reveal Creator Studio chooser through exact File > New")
        }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if exactEmptyProjectChooserIsVisible(runtime: runtime) {
                return await createEmptyProjectFromChooser(runtime: runtime)
            }
            // Logic does not always answer File > New with the chooser. Where the chooser is skipped
            // it creates the untitled project immediately and presents only the mandatory New Track
            // sheet — measured live: the arrange window read "Untitled 56 - Tracks" while this loop
            // was still waiting for a chooser that was never coming, and the operation then reported
            // failure for a project it had just created. A created project IS the requested outcome,
            // so accept it here rather than timing out beside it.
            if exactCreatedProjectWindow(runtime: runtime) != nil {
                return await observeProjectCreationOutcome(runtime: runtime, selection: "direct")
            }
        }
        return .error(
            "Exact File > New exposed neither the Creator Studio chooser nor a created project window"
        )
    }

    static func exactEmptyProjectChooserIsVisible(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Bool {
        exactEmptyProjectChooserWindow(runtime: runtime) != nil
    }

    private static func exactEmptyProjectChooserWindow(
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        let enumerated: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        let candidates: [AXUIElement]
        if enumerated.isEmpty,
           let main: AXUIElement = AXHelpers.getAttribute(
               app, kAXMainWindowAttribute as String, runtime: runtime.ax
           ) {
            candidates = [main]
        } else {
            // The Creator Studio chooser can be exposed as a dialog. The
            // generic mainWindow helper intentionally excludes dialogs to
            // protect arrange reads, so this chooser-only classifier must
            // inspect every AX window and still require one exact match.
            candidates = enumerated
        }
        let matches = candidates.filter { window in
            let emptyProjectLabels = AXHelpers.findAllDescendants(
                of: window, role: kAXStaticTextRole as String, maxDepth: 12, runtime: runtime.ax
            ).filter {
                let value = AXHelpers.getValue($0, runtime: runtime.ax) as? String
                return isExactEmptyProjectLabel(
                    title: AXHelpers.getTitle($0, runtime: runtime.ax), value: value
                )
            }
            let chooseButtons = AXHelpers.findAllDescendants(
                of: window, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
            ).filter { AXHelpers.getTitle($0, runtime: runtime.ax) == "Choose" }
            let chooseEnabled: Bool = chooseButtons.first.flatMap {
                AXHelpers.getAttribute($0, kAXEnabledAttribute as String, runtime: runtime.ax)
            } ?? false
            return chooserSelectionIsUnambiguous(
                windowTitle: AXHelpers.getTitle(window, runtime: runtime.ax),
                emptyProjectLabelCount: emptyProjectLabels.count,
                chooseButtonCount: chooseButtons.count,
                chooseEnabled: chooseEnabled
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

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

    static func isExactEmptyProjectLabel(title: String?, value: String?) -> Bool {
        title == "Empty Project" || value == "Empty Project"
    }

    static func isCreatedProjectWindowTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let arrangeSuffix = " - Tracks"
        return normalized.hasSuffix(arrangeSuffix) && normalized.count > arrangeSuffix.count
    }

    static func createdProjectWindowSelectionIsUnambiguous(
        windowTitle: String?,
        windowRole: String?,
        windowSubrole: String?
    ) -> Bool {
        windowRole == (kAXWindowRole as String)
            && windowSubrole == (kAXStandardWindowSubrole as String)
            && isCreatedProjectWindowTitle(windowTitle)
    }

    private static func exactCreatedProjectWindow(
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        var candidates: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        if candidates.isEmpty,
           let main: AXUIElement = AXHelpers.getAttribute(
               app, kAXMainWindowAttribute as String, runtime: runtime.ax
           ) {
            candidates = [main]
        }
        let matches = candidates.filter { window in
            createdProjectWindowSelectionIsUnambiguous(
                windowTitle: AXHelpers.getTitle(window, runtime: runtime.ax),
                windowRole: AXHelpers.getRole(window, runtime: runtime.ax),
                windowSubrole: AXHelpers.getAttribute(
                    window, kAXSubroleAttribute as String, runtime: runtime.ax
                )
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func observedWindowTitles(
        runtime: AXLogicProElements.Runtime
    ) -> [String] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        return windows.compactMap { AXHelpers.getTitle($0, runtime: runtime.ax) }
    }

    static func projectNewPendingReadbackEnvelope(
        mandatoryTrackCreated: Bool,
        observedWindowTitles: [String],
        observationBudgetMs: Int
    ) -> String {
        HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "operation": "project.new",
                "method": "accessibility",
                "selection": "Empty Project",
                "phase": "created_project_window_pending",
                "mandatory_track_created": mandatoryTrackCreated,
                "observed_window_titles": observedWindowTitles,
                "observation_budget_ms": observationBudgetMs,
                "write_attempted": true,
                "safe_to_retry": false,
            ]
        )
    }

    static func createEmptyProjectFromChooser(
        runtime: AXLogicProElements.Runtime = .production,
        observationAttempts: Int = 80,
        observationDelayNanoseconds: UInt64 = 250_000_000
    ) async -> ChannelResult {
        guard let window = exactEmptyProjectChooserWindow(runtime: runtime) else {
            return .error("Creator Studio project chooser is not visible")
        }
        let chooseButtons = AXHelpers.findAllDescendants(
            of: window, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter { AXHelpers.getTitle($0, runtime: runtime.ax) == "Choose" }
        let chooseEnabled: Bool = chooseButtons.first.flatMap {
            AXHelpers.getAttribute($0, kAXEnabledAttribute as String, runtime: runtime.ax)
        } ?? false

        guard chooseButtons.count == 1, chooseEnabled, let chooseButton = chooseButtons.first else {
            return .error("Creator Studio chooser is not the exact enabled Empty Project selection")
        }
        guard AXHelpers.performAction(chooseButton, kAXPressAction as String, runtime: runtime.ax) else {
            return .error("Failed to press the exact Creator Studio Choose button")
        }
        return await observeProjectCreationOutcome(
            runtime: runtime,
            selection: "Empty Project",
            observationAttempts: observationAttempts,
            observationDelayNanoseconds: observationDelayNanoseconds
        )
    }

    /// Watch for the project a `project.new` was asked to create, from whichever route produced it.
    ///
    /// Split out of `createEmptyProjectFromChooser` so the direct-creation route can reuse it. Logic
    /// does not always answer `File ▸ New` with the template chooser: on a machine where the chooser
    /// is skipped it creates the untitled project immediately and presents only the mandatory New
    /// Track sheet. That is the SAME outcome the chooser route reaches one step later, and it needs
    /// the same handling — the sheet reconciliation, the arrange-window witness, and the honest
    /// State B that leaves the independent Project-resource readback to the caller.
    static func observeProjectCreationOutcome(
        runtime: AXLogicProElements.Runtime,
        selection: String,
        observationAttempts: Int = 80,
        observationDelayNanoseconds: UInt64 = 250_000_000
    ) async -> ChannelResult {
        // Some Creator Studio builds open a zero-track Project directly, while
        // others expose Logic's mandatory New Track sheet. Reuse the existing
        // structural classifier for the sheet path: it only clicks Create when
        // the sheet is identified as mandatoryNewTrack; unknown sheets fail
        // closed. In either path, an exact English arrange-window title is the
        // bounded AX witness that the exact Empty Project selection completed.
        // The caller still performs independent Project-resource readback
        // before saving.
        var createdTrack = false
        let attempts = max(1, observationAttempts)
        for attempt in 0..<attempts {
            try? await Task.sleep(nanoseconds: observationDelayNanoseconds)
            let outcome = await reconcileAfterMutation(isDeleteContext: false, runtime: runtime)
            switch outcome.kind {
            case .mandatoryNewTrack:
                guard outcome.performed else {
                    return .error(HonestContract.encodeStateB(
                        reason: .readbackUnavailable,
                        extras: [
                            "operation": "project.new",
                            "method": "accessibility",
                            "selection": selection,
                            "phase": "mandatory_track_create_unconfirmed",
                            "write_attempted": true,
                            "safe_to_retry": false,
                        ]
                    ))
                }
                createdTrack = true
            case .unknownSheet, .deleteConfirm:
                return .error(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "operation": "project.new",
                        "method": "accessibility",
                        "selection": selection,
                        "phase": "unexpected_blocking_sheet",
                        "sheet_kind": String(describing: outcome.kind),
                        "write_attempted": true,
                        "safe_to_retry": false,
                    ]
                ))
            case .none, .informationalAlert, .strayMenu:
                break
            }
            if let current = exactCreatedProjectWindow(runtime: runtime) {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "operation": "project.new",
                        "method": "accessibility",
                        "selection": selection,
                        "phase": "created_project_window_observed",
                        "window_title": AXHelpers.getTitle(current, runtime: runtime.ax) ?? "",
                        "mandatory_track_created": createdTrack,
                        "observation_elapsed_ms": (attempt + 1) * Int(observationDelayNanoseconds / 1_000_000),
                        "write_attempted": true,
                        "safe_to_retry": false,
                    ]
                ))
            }
        }
        // The exact Choose press already crossed the write boundary. Creator
        // Studio may publish the generated Project bundle before its standard
        // arrange window stabilizes in AX. Report an honest State B and let the
        // qualification orchestrator perform its independent, run-owned
        // Project-resource readback; never misclassify this as a pre-write C or
        // trigger another project.new attempt.
        return .success(projectNewPendingReadbackEnvelope(
            mandatoryTrackCreated: createdTrack,
            observedWindowTitles: observedWindowTitles(runtime: runtime),
            observationBudgetMs: attempts * Int(observationDelayNanoseconds / 1_000_000)
        ))
    }

    // MARK: - Save As via AX Dialog

    static func saveAsDialogSelectionIsUnambiguous(
        containerRole: String?,
        containerSubrole: String?,
        windowTitle: String?,
        filenameFieldCount: Int,
        saveButtonCount: Int,
        saveEnabled: Bool,
        cancelButtonCount: Int,
        packageRadioCount: Int,
        folderRadioCount: Int
    ) -> Bool {
        let exactContainer = containerRole == (kAXSheetRole as String)
            || (containerRole == (kAXWindowRole as String)
                && containerSubrole == (kAXDialogSubrole as String))
        return exactContainer
            && windowTitle == "Save"
            && filenameFieldCount == 1
            && saveButtonCount == 1
            && saveEnabled
            && cancelButtonCount == 1
            && packageRadioCount == 1
            && folderRadioCount == 1
    }

    private static func exactSaveAsDialog(
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        var candidates: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        if let main = AXLogicProElements.mainWindow(runtime: runtime) {
            for child in AXHelpers.getChildren(main, runtime: runtime.ax) {
                let role = AXHelpers.getRole(child, runtime: runtime.ax)
                guard role == (kAXSheetRole as String) || role == (kAXWindowRole as String) else {
                    continue
                }
                if !candidates.contains(where: { CFEqual($0, child) }) {
                    candidates.append(child)
                }
            }
        }

        let matches = candidates.filter { candidate in
            let filenameFields = AXHelpers.findAllDescendants(
                of: candidate, role: kAXTextFieldRole as String, maxDepth: 12, runtime: runtime.ax
            ).filter { AXHelpers.getDescription($0, runtime: runtime.ax) == "text field" }
            let buttons = AXHelpers.findAllDescendants(
                of: candidate, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
            )
            let saveButtons = buttons.filter {
                AXLocalePolicy.elementMatches($0, AXLocalePolicy.saveConfirmationButton, runtime: runtime.ax)
            }
            let cancelButtons = buttons.filter {
                AXLocalePolicy.elementMatches($0, AXLocalePolicy.cancelButton, runtime: runtime.ax)
            }
            let saveEnabled: Bool = saveButtons.first.flatMap {
                AXHelpers.getAttribute($0, kAXEnabledAttribute as String, runtime: runtime.ax)
            } ?? false
            let radios = AXHelpers.findAllDescendants(
                of: candidate, role: kAXRadioButtonRole as String, maxDepth: 12, runtime: runtime.ax
            )
            return saveAsDialogSelectionIsUnambiguous(
                containerRole: AXHelpers.getRole(candidate, runtime: runtime.ax),
                containerSubrole: AXHelpers.getAttribute(
                    candidate, kAXSubroleAttribute as String, runtime: runtime.ax
                ),
                windowTitle: AXHelpers.getTitle(candidate, runtime: runtime.ax),
                filenameFieldCount: filenameFields.count,
                saveButtonCount: saveButtons.count,
                saveEnabled: saveEnabled,
                cancelButtonCount: cancelButtons.count,
                packageRadioCount: radios.filter {
                    AXHelpers.getTitle($0, runtime: runtime.ax) == "Package"
                }.count,
                folderRadioCount: radios.filter {
                    AXHelpers.getTitle($0, runtime: runtime.ax) == "Folder"
                }.count
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

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

        // Creator Studio 12.3 exposes this panel as a top-level AXDialog rather
        // than a child sheet. Accept either representation, but only after the
        // exact structural classifier finds one unambiguous Save As surface.
        var dialog: AXUIElement?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            dialog = exactSaveAsDialog(runtime: runtime)
            if dialog != nil { break }
        }

        guard let saveDialog = dialog else {
            return .error("Exact Save As dialog did not appear within 3 seconds")
        }

        // Helper: dismiss dialog on failure (press Escape to avoid blocking UI)
        func dismissDialog() {
            let cancelButtons = AXHelpers.findAllDescendants(of: saveDialog, role: "AXButton", runtime: runtime.ax)
            for btn in cancelButtons {
                if AXLocalePolicy.elementMatches(btn, AXLocalePolicy.cancelButton, runtime: runtime.ax) {
                    AXHelpers.performAction(btn, kAXPressAction, runtime: runtime.ax)
                    return
                }
            }
        }

        // Step 3: Find filename text field and set full path
        let filenameFields = AXHelpers.findAllDescendants(
            of: saveDialog, role: kAXTextFieldRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter { AXHelpers.getDescription($0, runtime: runtime.ax) == "text field" }
        guard filenameFields.count == 1, let filenameField = filenameFields.first else {
            dismissDialog()
            return .error("Cannot resolve the exact filename field in Save As dialog")
        }

        guard AXHelpers.setAttribute(
            filenameField, kAXValueAttribute, path as CFTypeRef, runtime: runtime.ax
        ) else {
            dismissDialog()
            return .error("Cannot set the exact Save As filename field")
        }
        // Confirm the text entry so the save panel updates its internal path state
        AXHelpers.performAction(filenameField, kAXConfirmAction, runtime: runtime.ax)
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for panel to process

        // Step 4: Find and click Save button
        let saveButtons = AXHelpers.findAllDescendants(
            of: saveDialog, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter {
            AXLocalePolicy.elementMatches($0, AXLocalePolicy.saveConfirmationButton, runtime: runtime.ax)
        }
        guard saveButtons.count == 1,
              let saveButton = saveButtons.first,
              AXHelpers.performAction(saveButton, kAXPressAction, runtime: runtime.ax) else {
            dismissDialog()
            return .error("Cannot press the exact Save button in Save As dialog")
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
