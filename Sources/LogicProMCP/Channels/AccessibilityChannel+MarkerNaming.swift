import ApplicationServices
import Foundation

extension AccessibilityChannel {
    enum MarkerRenameWriteResult: Sendable, Equatable {
        case notAttempted(HonestContract.FailureError)
        case attempted

        var writeAttempted: Bool { self == .attempted }

        var failureError: HonestContract.FailureError? {
            guard case .notAttempted(let error) = self else { return nil }
            return error
        }
    }

    static func renameSelectedMarker(
        _ name: String,
        in window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) async -> MarkerRenameWriteResult {
        let madeMain = AXHelpers.setAttribute(
            window,
            kAXMainAttribute,
            kCFBooleanTrue,
            runtime: runtime.ax
        )
        let raised = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        guard madeMain || raised else { return .notAttempted(.axWriteFailed) }
        usleep(100_000)

        guard let showControl = markerTextAreaToggle(in: window, runtime: runtime.ax) else {
            return .notAttempted(.axWriteFailed)
        }
        let showValue: NSNumber? = AXHelpers.getAttribute(
            showControl,
            kAXValueAttribute,
            runtime: runtime.ax
        )
        if showValue?.boolValue != true {
            guard AXHelpers.performAction(showControl, kAXPressAction, runtime: runtime.ax) else {
                return .notAttempted(.axWriteFailed)
            }
            usleep(100_000)
        }

        guard let editControl = markerEditControl(in: window, runtime: runtime.ax),
              AXHelpers.performAction(editControl, kAXPressAction, runtime: runtime.ax) else {
            return .notAttempted(.axWriteFailed)
        }
        usleep(100_000)

        let textAreas = AXHelpers.findAllDescendants(
            of: window,
            role: kAXTextAreaRole,
            maxDepth: 8,
            runtime: runtime.ax
        )
        guard let editor = textAreas.first,
              AXHelpers.setAttribute(
                editor,
                kAXFocusedAttribute,
                kCFBooleanTrue,
                runtime: runtime.ax
              ) else {
            return .notAttempted(.axWriteFailed)
        }
        usleep(50_000)
        let focused: NSNumber? = AXHelpers.getAttribute(
            editor,
            kAXFocusedAttribute,
            runtime: runtime.ax
        )
        guard focused?.boolValue == true else { return .notAttempted(.axWriteFailed) }

        if AXHelpers.setAttribute(
            editor,
            kAXValueAttribute,
            name as CFString,
            runtime: runtime.ax
        ) {
            _ = AXHelpers.performAction(editControl, kAXPressAction, runtime: runtime.ax)
            usleep(200_000)
            return .attempted
        }

        guard let windowTitle = AXHelpers.getTitle(window, runtime: runtime.ax) else {
            return .notAttempted(.axWriteFailed)
        }
        guard markerWindows(named: windowTitle, runtime: runtime).count == 1 else {
            return .notAttempted(.axWriteFailed)
        }
        let escapedName = AppleScriptSafety.escapeForScript(name)
        let escapedWindowTitle = AppleScriptSafety.escapeForScript(windowTitle)
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                set markerWindow to first window whose name is "\(escapedWindowTitle)"
                try
                    set markerGroup to first group of markerWindow whose description is "Marker"
                    set editButton to first button of markerGroup whose description is "Edit"
                on error
                    set markerGroup to first group of markerWindow whose description is "마커"
                    set editButton to first button of markerGroup whose description is "편집"
                end try
                set editor to first text area of first scroll area of markerGroup
                if focused of editor is false then error "marker editor is not focused"
                keystroke "a" using command down
                keystroke "\(escapedName)"
                delay 0.1
                click editButton
            end tell
        end tell
        return "renamed"
        """
        let result = await runtime.executeAppleScript(script)
        if !result.isSuccess,
           HonestContract.stateCErrorCode(result.message)
            == HonestContract.FailureError.systemEventsAutomationDenied.rawValue {
            return .notAttempted(.systemEventsAutomationDenied)
        }
        usleep(200_000)
        return .attempted
    }

    private static func markerWindows(
        named title: String,
        runtime: AXLogicProElements.Runtime
    ) -> [AXUIElement] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app,
            kAXWindowsAttribute,
            runtime: runtime.ax
        ) ?? []
        return windows.filter { AXHelpers.getTitle($0, runtime: runtime.ax) == title }
    }

    private static func markerTextAreaToggle(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.findAllDescendants(
            of: window,
            role: kAXCheckBoxRole,
            maxDepth: 8,
            runtime: runtime
        ).first {
            let label = (AXHelpers.getDescription($0, runtime: runtime) ?? "").lowercased()
            return label == "edit marker" || label == "마커 편집"
        }
    }

    private static func markerEditControl(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.findAllDescendants(
            of: window,
            role: kAXButtonRole,
            maxDepth: 8,
            runtime: runtime
        ).first {
            let label = (AXHelpers.getDescription($0, runtime: runtime) ?? "").lowercased()
            return label == "edit" || label == "편집"
        }
    }
}
