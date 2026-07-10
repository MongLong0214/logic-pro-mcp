import ApplicationServices
import Foundation

extension AccessibilityChannel {
    static func defaultToggleStepInputKeyboard(
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
              let windowMenu = AXLocalePolicy.findMenuBarItem(
                in: menuBar,
                matching: AXLocalePolicy.showStepInputKeyboardMenuPath.bar,
                runtime: runtime.ax
              ),
              let menuItem = AXLocalePolicy.findMenuItem(
                under: windowMenu,
                matching: AXLocalePolicy.showStepInputKeyboardMenuPath.item,
                mode: AXLocalePolicy.showStepInputKeyboardMenuPath.itemMode,
                runtime: runtime.ax
              ) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Window > Show Step Input Keyboard was not found."
            ))
        }

        let enabled: NSNumber? = AXHelpers.getAttribute(
            menuItem,
            kAXEnabledAttribute,
            runtime: runtime.ax
        )
        guard enabled?.boolValue != false else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Window > Show Step Input Keyboard is disabled."
            ))
        }

        let previousOpen = stepInputKeyboardIsOpen(app: app, runtime: runtime.ax)
        guard AXHelpers.performAction(menuItem, kAXPressAction, runtime: runtime.ax) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "AXPress failed on Window > Show Step Input Keyboard."
            ))
        }

        for _ in 0..<20 {
            let observedOpen = stepInputKeyboardIsOpen(app: app, runtime: runtime.ax)
            if observedOpen != previousOpen {
                return .success(HonestContract.encodeStateA(extras: [
                    "operation": "edit.toggle_step_input",
                    "previous_open": previousOpen,
                    "observed_open": observedOpen,
                    "via": "window-menu",
                ]))
            }
            usleep(50_000)
        }

        return .error(HonestContract.encodeStateC(
            error: .readbackMismatch,
            hint: "Step Input Keyboard window state did not change after the menu action.",
            extras: [
                "operation": "edit.toggle_step_input",
                "previous_open": previousOpen,
                "observed_open": previousOpen,
                "safe_to_retry": true,
            ]
        ))
    }

    private static func stepInputKeyboardIsOpen(
        app: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app,
            kAXWindowsAttribute,
            runtime: runtime
        ) ?? []
        return windows.contains { window in
            AXLocalePolicy.stepInputKeyboardWindowTitle.matches(
                AXHelpers.getTitle(window, runtime: runtime),
                mode: .contains
            )
        }
    }
}
