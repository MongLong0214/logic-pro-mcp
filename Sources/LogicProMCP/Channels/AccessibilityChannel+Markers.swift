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
        if let requestedName, !requestedName.isEmpty,
           let currentWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
            nameApplied = await renameSelectedMarker(
                requestedName,
                in: currentWindow,
                runtime: runtime
            )
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
            extras["name_applied"] = nameApplied ?? false
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: extras
        ))
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
                    set targetItem to menu item "\(englishItem)" of menu 1 of menu bar item "Navigate" of menu bar 1
                    if enabled of targetItem is false then error "menu item disabled"
                    click targetItem
                else
                    click menu bar item "탐색" of menu bar 1
                    delay 0.1
                    set targetItem to menu item "\(koreanItem)" of menu 1 of menu bar item "탐색" of menu bar 1
                    if enabled of targetItem is false then error "menu item disabled"
                    click targetItem
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
