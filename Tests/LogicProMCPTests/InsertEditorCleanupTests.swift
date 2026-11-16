@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Logic Pro 13.0 (7801, Korean) after insert_verified mounted Gain on a new audio track, measured
// 2026-11-16 in the Aqua session (impl-logic13/A14-insert-focus.*, A16-wins.stdout): AXWindows held
// the main window plus a new AXDialog titled "오디오 2" (the plug-in editor), AXFocusedWindow was that
// editor and AXFocusedUIElement answered -25212. Once the editor closed, Logic gave the key view to
// the "오디오 1" channel-strip group instead of the pre-insert focus (B6-insert-focus-fix2.stdout).
// No AX element is read from a running Logic.
private struct EditorFixture {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let main: AXUIElement
    let editor: AXUIElement
    let close: AXUIElement
    let priorFocus: AXUIElement
    let strip: AXUIElement
    let pressed = MutableBox(0)
    let focusWrites = MutableBox(0)

    init(closeTakesEffect: Bool, focusReturnsToMain: Bool) {
        let b = builder
        app = b.element(0); main = b.element(1); editor = b.element(2); close = b.element(3)
        priorFocus = b.element(4); strip = b.element(5)
        b.setRole(priorFocus, kAXGroupRole as String)
        b.setAttribute(priorFocus, kAXDescriptionAttribute as String, "믹서")
        b.setAttributeSettable(priorFocus, kAXFocusedAttribute as String, true)
        b.setRole(strip, kAXLayoutItemRole as String)
        b.setAttribute(app, kAXFocusedUIElementAttribute as String, priorFocus)
        b.setRole(main, kAXWindowRole as String)
        b.setAttribute(main, kAXTitleAttribute as String, "NativeLogic13-9995.logicx - 트랙")
        b.setRole(editor, kAXWindowRole as String)
        b.setAttribute(editor, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(editor, kAXTitleAttribute as String, "오디오 2")
        b.setAttribute(editor, kAXCloseButtonAttribute as String, close)
        b.setRole(close, kAXButtonRole as String)
        b.setAttribute(close, kAXWindowAttribute as String, editor)
        b.setAttribute(app, kAXWindowsAttribute as String, [main])
        b.setAttribute(app, kAXMainWindowAttribute as String, main)
        b.setAttribute(app, kAXFocusedWindowAttribute as String, main)
    }

    /// The editor appears after the baseline, exactly as the slot pick makes Logic open it.
    func openEditor() {
        builder.setAttribute(app, kAXWindowsAttribute as String, [main, editor])
        builder.setAttribute(app, kAXFocusedWindowAttribute as String, editor)
        builder.removeAttribute(app, kAXFocusedUIElementAttribute as String)
    }

    func runtime(closeTakesEffect: Bool, focusReturnsToMain: Bool, focusWriteTakesEffect: Bool = true) -> AXLogicProElements.Runtime {
        let b = builder, app = app, main = main, close = close, pressed = pressed
        let prior = priorFocus, strip = strip, writes = focusWrites
        return b.makeLogicRuntime(appElement: app, setAttributeHandler: { element, attribute, _ in
            guard CFEqual(element, prior), attribute == (kAXFocusedAttribute as String) else { return false }
            writes.value += 1
            if focusWriteTakesEffect { b.setAttribute(app, kAXFocusedUIElementAttribute as String, prior) }
            return true
        }, performActionHandler: { element, action in
            guard CFEqual(element, close), action == (kAXPressAction as String) else { return false }
            pressed.value += 1
            if closeTakesEffect {
                b.setAttribute(app, kAXWindowsAttribute as String, [main])
                b.setAttribute(app, kAXFocusedUIElementAttribute as String, strip)
                if focusReturnsToMain { b.setAttribute(app, kAXFocusedWindowAttribute as String, main) }
                else { b.removeAttribute(app, kAXFocusedWindowAttribute as String) }
            }
            return true
        })
    }
}

@Test func insertClosesTheEditorItOpenedAndReadsBackMainWindowFocus() throws {
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: true)
    let runtime = f.runtime(closeTakesEffect: true, focusReturnsToMain: true)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    let result = AccessibilityChannel.closeEditorsOpenedByInsert(
        since: baseline, pluginID: "logic.stock.effect.gain", runtime: runtime)
    #expect(result["post_insert_editor_windows_opened"] as? Int == 1)
    #expect(f.pressed.value == 1)
    let editorWindowsClosed = try #require(result["post_insert_editor_windows_closed"] as? Bool)
    #expect(editorWindowsClosed)
    let mainWindowFocused = try #require(result["post_insert_main_window_focused"] as? Bool)
    #expect(mainWindowFocused)
    #expect(f.focusWrites.value == 1)
    let focusRestored = try #require(result["post_insert_focus_restored"] as? Bool)
    #expect(focusRestored)
    let editorCleanupObserved = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(editorCleanupObserved)
}

@Test func insertFocusWriteThatDoesNotLandIsNotReportedRestored() throws {
    // AX answers success to the focus write but the key view stays on the strip (Logic 13 group targets).
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: true)
    let runtime = f.runtime(closeTakesEffect: true, focusReturnsToMain: true, focusWriteTakesEffect: false)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    let result = AccessibilityChannel.closeEditorsOpenedByInsert(
        since: baseline, pluginID: "logic.stock.effect.gain", runtime: runtime)
    let editorWindowsClosed = try #require(result["post_insert_editor_windows_closed"] as? Bool)
    #expect(editorWindowsClosed)
    let focusRestoreAttempted = try #require(result["post_insert_focus_restore_attempted"] as? Bool)
    #expect(focusRestoreAttempted)
    let focusRestored = try #require(result["post_insert_focus_restored"] as? Bool)
    #expect(!focusRestored)
    let editorCleanupObserved = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!editorCleanupObserved)
}

@Test func insertEditorThatStaysOpenIsNotReportedClosed() throws {
    let f = EditorFixture(closeTakesEffect: false, focusReturnsToMain: false)
    let runtime = f.runtime(closeTakesEffect: false, focusReturnsToMain: false)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    let result = AccessibilityChannel.closeEditorsOpenedByInsert(
        since: baseline, pluginID: "logic.stock.effect.gain", runtime: runtime)
    let editorWindowsClosed = try #require(result["post_insert_editor_windows_closed"] as? Bool)
    #expect(!editorWindowsClosed)
    let editorCleanupObserved = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!editorCleanupObserved)
}

@Test func insertEditorClosedWithoutMainFocusIsNotReportedRestored() throws {
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: false)
    let runtime = f.runtime(closeTakesEffect: true, focusReturnsToMain: false)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    let result = AccessibilityChannel.closeEditorsOpenedByInsert(
        since: baseline, pluginID: "logic.stock.effect.gain", runtime: runtime)
    let editorWindowsClosed = try #require(result["post_insert_editor_windows_closed"] as? Bool)
    #expect(editorWindowsClosed)
    let mainWindowFocused = try #require(result["post_insert_main_window_focused"] as? Bool)
    #expect(!mainWindowFocused)
    let editorCleanupObserved = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!editorCleanupObserved)
}

@Test func insertWithoutReadableBaselineFailsClosed() throws {
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: true)
    let runtime = f.runtime(closeTakesEffect: true, focusReturnsToMain: true)
    f.openEditor()
    let result = AccessibilityChannel.closeEditorsOpenedByInsert(
        since: nil, pluginID: "logic.stock.effect.gain", runtime: runtime)
    let editorCleanupObserved = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!editorCleanupObserved)
    #expect(f.pressed.value == 0)
}
