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
                hint: "Window > Step Input Keyboard was not found."
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
                hint: "Window > Step Input Keyboard is disabled."
            ))
        }

        let previousOpen = stepInputKeyboardIsOpen(app: app, runtime: runtime.ax)
        guard AXHelpers.performAction(menuItem, kAXPressAction, runtime: runtime.ax) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "AXPress failed on Window > Step Input Keyboard."
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

// MARK: - #864 verified undo / redo

extension AccessibilityChannel {
    /// Undo (or redo) through Logic's own Edit menu, and say WHAT was undone.
    ///
    /// #864 — `edit.undo` routed `[.midiKeyCommands, .cgEvent]`, and the MIDI channel sent CC 30 on
    /// channel 16: a controller number that does nothing unless the operator bound it in Controller
    /// Assignments, which this product can neither create nor enumerate. The `.cgEvent` rung that
    /// would post a real Cmd+Z was never reached, because a send-only channel succeeds at the wire
    /// and nothing falls through. Measured 2026-09-12: two inserted plug-ins survived two
    /// `logic_edit undo` calls, each answering `success: true`.
    ///
    /// The readback is the menu item's own title, and it exists only because of a measurement that
    /// is easy to get wrong: **the title is plain `Undo` until the menu is OPENED**, after which it
    /// reads `Undo Insert Plug-in in Channel Strip`. Reading it without opening returns the bare
    /// word and would make every undo look identical. `AXEnabled`, by contrast, IS readable
    /// unopened — which is why "nothing to undo" can be refused before anything is pressed.
    ///
    /// So State A means the stack MOVED: the entry named before the press is not the entry named
    /// after it. When the two names match, this surface cannot separate a pop from a no-op — Logic
    /// can legitimately offer the same wording twice — and that is State B, not a claim.
    /// Open a menu-bar item and confirm it actually opened.
    ///
    /// #864 — this operation opens the Edit menu three times (read, press, read), and AXPress on a
    /// menu-bar item TOGGLES. A press that arrives while the previous Escape is still settling
    /// closes the menu instead of opening it, and the row search then finds nothing — which this
    /// function would have reported as "the entry vanished", a confident false statement about
    /// Logic caused by our own pacing. So the open is confirmed by looking for the AXMenu child
    /// rather than by the action's return value, and retried once. AX actions report what the API
    /// returned, not what the application did.
    private static func openMenuAndConfirm(
        _ barItem: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) async -> Bool {
        for attempt in 0..<2 {
            if !AXHelpers.getChildren(barItem, runtime: runtime.ax).contains(where: {
                (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXMenuRole as String)
            }) {
                _ = AXHelpers.performAction(barItem, kAXPressAction, runtime: runtime.ax)
            }
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 200 : 450))
            if AXHelpers.getChildren(barItem, runtime: runtime.ax).contains(where: {
                (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXMenuRole as String)
            }) {
                return true
            }
        }
        return false
    }

    /// The Edit menu's Undo or Redo row, identified by its SHORTCUT.
    ///
    /// #864 — the wording cannot be the identity, and the first attempt at this proved it by
    /// picking the wrong row. Measured 2026-09-12 and recorded in
    /// `docs/observations/2026-09-12-the-undo-entry-is-identified-by-its-shortcut-not-its-wording.json`:
    ///
    ///     Can't Undo                            cmdChar Z  mods 0   enabled false
    ///     Redo Insert Plug-in in Channel Strip  cmdChar Z  mods 1   enabled true
    ///     Undo History…                         cmdChar Z  mods 6   enabled true
    ///     Delete Undo History                   cmdChar -  mods 8   enabled true
    ///
    /// The title is LOCALIZED and STATE-DEPENDENT. With an empty stack it reads `Can't Undo`, which
    /// does not START with `Undo`, so a prefix match skips it and lands on `Undo History…` — the one
    /// title that does. Widening to containment is worse, not better: three titles carry the word,
    /// and pressing `Undo History…` opens a window instead of undoing anything. That is exactly what
    /// the first version of this function did.
    ///
    /// The shortcut is unique: ⌘Z for undo, ⇧⌘Z for redo (mask bit 0 is shift). When the shortcut
    /// attributes cannot be read the answer is nil and the caller refuses — a host that has remapped
    /// ⌘Z is told the row could not be identified rather than having a different row pressed on its
    /// behalf.
    static func editStackEntry(
        under barItem: AXUIElement,
        redo: Bool,
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        let wantedModifiers = redo ? 1 : 0
        for menu in AXHelpers.getChildren(barItem, runtime: runtime.ax) {
            for item in AXHelpers.getChildren(menu, runtime: runtime.ax) {
                let char: String? = AXHelpers.getAttribute(
                    item, "AXMenuItemCmdChar", runtime: runtime.ax
                )
                guard char?.uppercased() == "Z" else { continue }
                let modifiers: NSNumber? = AXHelpers.getAttribute(
                    item, "AXMenuItemCmdModifiers", runtime: runtime.ax
                )
                guard let modifiers, modifiers.intValue == wantedModifiers else { continue }
                return item
            }
        }
        return nil
    }

    static func defaultUndoOrRedo(
        redo: Bool,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        let operation = redo ? "edit.redo" : "edit.undo"
        // The MENU BAR item is still found by name -- that title is stable and localized, and the
        // census tries each measured spelling. Only the ROW inside it needs the shortcut, because
        // only the row's title moves with the undo stack.
        let barLabels = AXLocalePolicy.editMenuBar

        func readEntry() async -> (title: String, enabled: Bool)? {
            _ = ProcessUtils.Runtime.production.activateLogicPro()
            guard let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
                  let barItem = AXLocalePolicy.findMenuBarItem(
                    in: menuBar, matching: barLabels, runtime: runtime.ax
                  ) else { return nil }
            // OPEN IT. The title is only populated while the menu is open — see the note above.
            guard await openMenuAndConfirm(barItem, runtime: runtime) else { return nil }
            guard let item = editStackEntry(under: barItem, redo: redo, runtime: runtime) else {
                AXMouseHelper.pressEscape()
                return nil
            }
            let title: String = AXHelpers.getAttribute(item, kAXTitleAttribute, runtime: runtime.ax) ?? ""
            let enabled: Bool = AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: runtime.ax) ?? true
            AXMouseHelper.pressEscape()
            try? await Task.sleep(for: .milliseconds(120))
            return (title, enabled)
        }

        guard let before = await readEntry() else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Logic's Edit menu did not offer a readable \(redo ? "Redo" : "Undo") entry",
                extras: ["operation": operation, "write_attempted": false]
            ))
        }
        guard before.enabled else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "there is nothing to \(redo ? "redo" : "undo"): Logic's Edit menu entry is disabled",
                extras: [
                    "operation": operation,
                    "entry_before": before.title,
                    "write_attempted": false,
                ]
            ))
        }

        _ = ProcessUtils.Runtime.production.activateLogicPro()
        guard let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
              let barItem = AXLocalePolicy.findMenuBarItem(
                in: menuBar, matching: barLabels, runtime: runtime.ax
              ),
              await openMenuAndConfirm(barItem, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Logic's Edit menu would not open",
                extras: ["operation": operation, "write_attempted": false]
            ))
        }
        guard let item = editStackEntry(under: barItem, redo: redo, runtime: runtime) else {
            AXMouseHelper.pressEscape()
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "the \(redo ? "Redo" : "Undo") entry vanished between reading it and pressing it",
                extras: ["operation": operation, "write_attempted": false]
            ))
        }
        // The press result is NOT the verdict. An AX action reports what the API returned, not what
        // the application did, so the entry is re-read below and only a moved stack is State A.
        let pressed = AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax)
        try? await Task.sleep(for: .milliseconds(700))

        let after = await readEntry()
        var extras: [String: Any] = [
            "operation": operation,
            "entry_before": before.title,
            "entry_after": after?.title ?? "",
            "write_attempted": true,
            "press_reported": pressed,
            "verify_source": "ax_edit_menu_entry",
        ]
        guard let after else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        guard after.title != before.title else {
            extras["reason_detail"] = "the Edit menu names the same entry before and after, so this "
                + "surface cannot separate a stack that moved from one that did not"
            return .success(HonestContract.encodeStateB(
                reason: .noopUnobservable,
                extras: extras
            ))
        }
        extras["verified"] = true
        return .success(HonestContract.encodeStateA(extras: extras))
    }
}
