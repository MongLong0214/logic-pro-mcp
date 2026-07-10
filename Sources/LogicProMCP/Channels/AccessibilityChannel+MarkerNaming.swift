import ApplicationServices
import Foundation

extension AccessibilityChannel {
    static func renameSelectedMarker(
        _ name: String,
        in window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) async -> Bool {
        let madeMain = AXHelpers.setAttribute(
            window,
            kAXMainAttribute,
            kCFBooleanTrue,
            runtime: runtime.ax
        )
        let raised = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        guard madeMain || raised else { return false }
        usleep(100_000)

        guard let showControl = markerTextAreaToggle(in: window, runtime: runtime.ax) else {
            return false
        }
        let showValue: NSNumber? = AXHelpers.getAttribute(
            showControl,
            kAXValueAttribute,
            runtime: runtime.ax
        )
        if showValue?.boolValue != true {
            guard AXHelpers.performAction(showControl, kAXPressAction, runtime: runtime.ax) else {
                return false
            }
            usleep(100_000)
        }

        guard let editControl = markerEditControl(in: window, runtime: runtime.ax),
              AXHelpers.performAction(editControl, kAXPressAction, runtime: runtime.ax) else {
            return false
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
            return false
        }
        usleep(50_000)
        let focused: NSNumber? = AXHelpers.getAttribute(
            editor,
            kAXFocusedAttribute,
            runtime: runtime.ax
        )
        guard focused?.boolValue == true else { return false }

        let escapedName = AppleScriptSafety.escapeForScript(name)
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                try
                    set markerWindow to first window whose name contains "Marker List"
                    set markerGroup to first group of markerWindow whose description is "Marker"
                    set editButton to first button of markerGroup whose description is "Edit"
                on error
                    set markerWindow to first window whose name contains "마커 목록"
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
        let renameResult = await AppleScriptChannel.executeAppleScript(script)
        guard renameResult.isSuccess else { return false }
        usleep(200_000)

        let markers = AXLogicProElements.enumerateMarkersFromListWindow(
            window,
            runtime: runtime.ax
        )
        return markers.contains { $0.name == name }
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
