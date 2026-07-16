import ApplicationServices
import Foundation

extension AccessibilityChannel {
    static func defaultOpenMarkerList(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        if AXLogicProElements.findMarkerListWindow(runtime: runtime) != nil {
            return .success(HonestContract.encodeStateA(extras: [
                "operation": "nav.open_marker_list",
                "already_open": true,
            ]))
        }
        if AXLogicProElements.hasUnverifiedMarkerListWindow(runtime: runtime) {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The requested marker view could not be verified.",
                extras: [
                    "operation": "nav.open_marker_list",
                    "write_attempted": false,
                ]
            ))
        }
        let menuResult = await pressMarkerMenuItem(.openList)
        guard menuResult.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Navigate > Open Marker List was not found or could not be pressed."
            ))
        }
        for _ in 0..<20 {
            if AXLogicProElements.findMarkerListWindow(runtime: runtime) != nil {
                return .success(HonestContract.encodeStateA(extras: [
                    "operation": "nav.open_marker_list",
                    "already_open": false,
                ]))
            }
            usleep(50_000)
        }
        return .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "Navigate > Open Marker List was pressed, but the Marker List window did not appear."
        ))
    }

    static func defaultCreateMarker(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        let openResult = await defaultOpenMarkerList(runtime: runtime)
        guard openResult.isSuccess,
              let listWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) else {
            return openResult
        }

        let before = AXLogicProElements.enumerateMarkersFromListWindow(
            listWindow,
            runtime: runtime.ax
        )
        guard focusArrangeWindow(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "The arrange window could not be focused before creating a marker."
            ))
        }
        let menuResult = await pressMarkerMenuItem(.create)
        guard menuResult.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Navigate > Create Marker was not found or could not be pressed."
            ))
        }

        var after = before
        for _ in 0..<20 {
            usleep(50_000)
            guard let currentWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) else {
                continue
            }
            after = AXLogicProElements.enumerateMarkersFromListWindow(
                currentWindow,
                runtime: runtime.ax
            )
            if after.count > before.count {
                break
            }
        }

        let requestedName = params["name"]
        var nameApplied: Bool? = nil
        var nameWriteAttempted: Bool? = nil
        if let requestedName, !requestedName.isEmpty,
           let currentWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
            let write = await renameSelectedMarker(
                requestedName,
                in: currentWindow,
                runtime: runtime
            )
            nameWriteAttempted = write.writeAttempted
            if !write.writeAttempted {
                nameApplied = false
            }
        }

        var extras: [String: Any] = [
            "operation": "nav.create_marker",
            "method": "accessibility_menu",
            "menu_path": "Navigate > Create Marker",
            "sent": true,
            "marker_count_before_channel": before.count,
            "marker_count_after_channel": after.count,
        ]
        if let requestedName, !requestedName.isEmpty {
            extras["requested_name"] = requestedName
            if let nameApplied {
                extras["name_applied"] = nameApplied
            }
            if let nameWriteAttempted {
                extras["name_write_attempted"] = nameWriteAttempted
            }
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: extras
        ))
    }

    static func defaultRenameMarker(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let rawIndex = params["index"], let index = Int(rawIndex), index >= 0,
              let name = params["name"], !name.isEmpty else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "nav.rename_marker requires an index >= 0 and a non-empty name"
            ))
        }
        guard !AXLogicProElements.hasUnverifiedMarkerListWindow(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The requested marker target could not be verified.",
                extras: [
                    "operation": "nav.rename_marker",
                    "requested_index": index,
                    "requested_name": name,
                    "write_attempted": false,
                ]
            ))
        }
        let openResult = await defaultOpenMarkerList(runtime: runtime)
        guard openResult.isSuccess else {
            return openResult
        }
        guard let binding = AXLogicProElements.markerListBinding(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The requested marker target could not be verified after opening.",
                extras: [
                    "operation": "nav.rename_marker",
                    "requested_index": index,
                    "requested_name": name,
                    "write_attempted": false,
                ]
            ))
        }
        let window = binding.window
        let before = AXLogicProElements.enumerateMarkersFromListWindow(
            window,
            runtime: runtime.ax
        )
        guard let target = before.first(where: { $0.id == index }) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Marker index \(index) was not found in the Marker List",
                extras: ["requested_index": index, "marker_count": before.count]
            ))
        }
        let stablePosition = target.positionSource == .parser
            && before.filter({ $0.position == target.position }).count == 1
            ? target.position
            : nil
        if target.name == name {
            let extras: [String: Any] = [
                "operation": "nav.rename_marker",
                "index": index,
                "previous_name": target.name,
                "requested_name": name,
                "observed_name": target.name,
                "write_attempted": false,
            ]
            guard stablePosition != nil else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            }
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        guard selectMarkerRow(index, in: window, runtime: runtime.ax) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Marker index \(index) could not be selected",
                extras: ["write_attempted": false]
            ))
        }
        let write = await renameSelectedMarker(name, in: window, runtime: runtime)
        var extras: [String: Any] = [
            "operation": "nav.rename_marker",
            "index": index,
            "previous_name": target.name,
            "requested_name": name,
            "write_attempted": write.writeAttempted,
        ]
        guard write.writeAttempted else {
            return .error(HonestContract.encodeStateC(
                error: write.failureError ?? .axWriteFailed,
                hint: "The selected marker name write could not be attempted",
                extras: extras
            ))
        }

        guard let stablePosition,
              let currentBinding = AXLogicProElements.markerListBinding(runtime: runtime),
              currentBinding.projectDocument == binding.projectDocument,
              CFEqual(currentBinding.window, binding.window) else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        let matches = AXLogicProElements.enumerateMarkersFromListWindow(
            currentBinding.window,
            runtime: runtime.ax
        ).filter { $0.positionSource == .parser && $0.position == stablePosition }
        guard matches.count == 1 else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        let observed = matches[0]
        extras["observed_name"] = observed.name
        guard observed.name == name else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extras
            ))
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    private static func selectMarkerRow(
        _ index: Int,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let table = AXHelpers.findAllDescendants(
            of: window,
            role: kAXTableRole,
            maxDepth: 8,
            runtime: runtime
        ).first else { return false }
        let rows: [AXUIElement] = AXHelpers.getAttribute(
            table,
            "AXRows",
            runtime: runtime
        ) ?? AXHelpers.getChildren(table, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXRowRole as String)
        }
        guard rows.indices.contains(index) else { return false }
        let row = rows[index]
        if AXHelpers.setAttribute(
            table,
            kAXSelectedRowsAttribute,
            [row] as CFArray,
            runtime: runtime
        ) {
            return true
        }
        return AXHelpers.setAttribute(
            row,
            kAXSelectedAttribute,
            kCFBooleanTrue,
            runtime: runtime
        )
    }

    private enum MarkerMenuAction {
        case openList
        case create
    }

    private static func pressMarkerMenuItem(_ action: MarkerMenuAction) async -> ChannelResult {
        let target = LogicProTarget.appleScriptTarget()
        let englishItem: String
        let koreanItem: String
        switch action {
        case .openList:
            englishItem = "Open Marker List"
            koreanItem = "마커 목록 열기"
        case .create:
            englishItem = "Create Marker"
            koreanItem = "마커 생성"
        }
        let focusBlock: String
        switch action {
        case .create:
            focusBlock = """
                try
                    set targetWindow to first window whose name ends with "Tracks"
                on error
                    set targetWindow to first window whose name ends with "트랙"
                end try
                set value of attribute "AXMain" of targetWindow to true
                perform action "AXRaise" of targetWindow
                delay 0.1
            """
        case .openList:
            focusBlock = ""
        }
        let script = """
        \(target.activateByBundleID)
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                set frontmost to true
        \(focusBlock)
                if exists menu bar item "Navigate" of menu bar 1 then
                    click menu bar item "Navigate" of menu bar 1
                    delay 0.1
                    -- #346: once the menu is open, ANY failure (item missing on a
                    -- wrong locale, or disabled) must Escape it before erroring so
                    -- the Navigate menu is never left open (wedging Logic).
                    try
                        set targetItem to menu item "\(englishItem)" of menu 1 of menu bar item "Navigate" of menu bar 1
                        if enabled of targetItem is false then error "menu item disabled"
                        click targetItem
                    on error errMsg
                        key code 53
                        delay 0.1
                        error errMsg
                    end try
                else
                    click menu bar item "탐색" of menu bar 1
                    delay 0.1
                    try
                        set targetItem to menu item "\(koreanItem)" of menu 1 of menu bar item "탐색" of menu bar 1
                        if enabled of targetItem is false then error "menu item disabled"
                        click targetItem
                    on error errMsg
                        key code 53
                        delay 0.1
                        error errMsg
                    end try
                end if
            end tell
        end tell
        return "clicked"
        """
        return await AppleScriptChannel.executeAppleScript(script)
    }

    private static func focusArrangeWindow(runtime: AXLogicProElements.Runtime) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return false
        }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app,
            kAXWindowsAttribute,
            runtime: runtime.ax
        ) ?? []
        let candidates = windows.filter { window in
            let title = AXHelpers.getTitle(window, runtime: runtime.ax) ?? ""
            let isMarkerList = AXLocalePolicy.markerListWindowSuffixes.contains {
                title.hasSuffix($0)
            }
            let subrole: String? = AXHelpers.getAttribute(
                window,
                kAXSubroleAttribute,
                runtime: runtime.ax
            )
            let isDialog = subrole == (kAXDialogSubrole as String)
                || subrole == (kAXSystemDialogSubrole as String)
            return !isMarkerList && !isDialog
        }
        let window = candidates.max { lhs, rhs in
            let left = AXHelpers.getSize(lhs, runtime: runtime.ax) ?? .zero
            let right = AXHelpers.getSize(rhs, runtime: runtime.ax) ?? .zero
            return left.width * left.height < right.width * right.height
        } ?? AXLogicProElements.mainWindow(runtime: runtime)
        guard let window else { return false }
        let madeMain = AXHelpers.setAttribute(
            window,
            kAXMainAttribute,
            kCFBooleanTrue,
            runtime: runtime.ax
        )
        let raised = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        usleep(100_000)
        return madeMain || raised
    }

}
