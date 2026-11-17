@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Logic Pro 13.0 (7801, Korean) after insert_verified mounted Gain on a new audio track, measured
// 2026-11-16 in the Aqua session (impl-logic13/A14-insert-focus.*, A16-wins.stdout): AXWindows held
// the main window plus a new AXDialog titled "오디오 2" (the plug-in editor), AXFocusedWindow was that
// editor and AXFocusedUIElement answered -25212. Once the editor closed, Logic gave the key view to
// the "오디오 1" channel-strip group instead of the pre-insert focus (B6-insert-focus-fix2.stdout).
// The editor's direct children are Logic 13's measured plug-in editor header (a Compressor editor on "Studio Grand"): a 닫기 button, a 바이패스 AXCheckBox and
// two direct AXStaticText values, the plug-in name and the track name. Here they read "Gain" and
// "오디오 2", the names the insert of Gain on "오디오 2" observed (B8-insert-focus-fix3).
// No AX element is read from a running Logic.
private final class WindowList: @unchecked Sendable {
    var windows: [AXUIElement] = []
}

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
    let list = WindowList()

    init(closeTakesEffect: Bool, focusReturnsToMain: Bool, editorPluginName: String = "Gain") {
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
        Self.makeEditor(b, editor, close: close, base: 10, title: "오디오 2", pluginName: editorPluginName)
        list.windows = [main]
        b.setAttribute(app, kAXMainWindowAttribute as String, main)
        b.setAttribute(app, kAXFocusedWindowAttribute as String, main)
    }

    /// A Logic 13 plug-in editor window: AXDialog, close button, bypass toggle, plug-in and track header.
    static func makeEditor(
        _ b: FakeAXRuntimeBuilder, _ window: AXUIElement, close: AXUIElement, base: Int, title: String, pluginName: String
    ) {
        b.setRole(window, kAXWindowRole as String)
        b.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(window, kAXTitleAttribute as String, title)
        b.setAttribute(window, kAXCloseButtonAttribute as String, close)
        b.setRole(close, kAXButtonRole as String)
        b.setAttribute(close, kAXDescriptionAttribute as String, "닫기")
        b.setAttribute(close, kAXWindowAttribute as String, window)
        let bypass = b.element(base), pluginText = b.element(base + 1), trackText = b.element(base + 2)
        b.setRole(bypass, kAXCheckBoxRole as String)
        b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
        b.setRole(pluginText, kAXStaticTextRole as String)
        b.setAttribute(pluginText, kAXValueAttribute as String, pluginName)
        b.setRole(trackText, kAXStaticTextRole as String)
        b.setAttribute(trackText, kAXValueAttribute as String, title)
        b.setChildren(window, [close, bypass, pluginText, trackText])
    }

    /// The editor appears after the baseline, exactly as the slot pick makes Logic open it.
    func openEditor() {
        list.windows = [main, editor]
        builder.setAttribute(app, kAXFocusedWindowAttribute as String, editor)
        builder.removeAttribute(app, kAXFocusedUIElementAttribute as String)
    }

    func cleanup(
        _ baseline: AccessibilityChannel.InsertEditorWindowBaseline?, runtime: AXLogicProElements.Runtime,
        trackName: String? = "오디오 2", targetIsCurrent: @escaping () -> Bool = { true }
    ) -> [String: Any] {
        AccessibilityChannel.closeEditorsOpenedByInsert(
            since: baseline, pluginID: "logic.stock.effect.gain", trackName: trackName,
            observedPluginName: "Gain", targetIsCurrent: targetIsCurrent, runtime: runtime)
    }

    /// `otherCloses`: other windows' close buttons, pressed into `otherPresses`; they close their window.
    func runtime(
        closeTakesEffect: Bool, focusReturnsToMain: Bool, focusWriteTakesEffect: Bool = true,
        otherCloses: [(button: AXUIElement, window: AXUIElement)] = [], otherPresses: MutableBox<Int> = MutableBox(0)
    ) -> AXLogicProElements.Runtime {
        let b = builder, app = app, main = main, close = close, pressed = pressed, editor = editor, list = list
        let prior = priorFocus, strip = strip, writes = focusWrites
        let others = otherCloses.map { (b.elementID($0.button), $0.window) }
        return b.makeLogicRuntime(appElement: app, attributeValueHandler: { element, attribute -> AnyObject?? in
            guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
            return .some(list.windows as NSArray)
        }, attributeValueResultHandler: { element, attribute in
            guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
            return .success(list.windows as NSArray)
        }, setAttributeHandler: { element, attribute, _ in
            guard CFEqual(element, prior), attribute == (kAXFocusedAttribute as String) else { return false }
            writes.value += 1
            if focusWriteTakesEffect { b.setAttribute(app, kAXFocusedUIElementAttribute as String, prior) }
            return true
        }, performActionHandler: { element, action in
            guard action == (kAXPressAction as String) else { return false }
            if let other = others.first(where: { $0.0 == b.elementID(element) }) {
                otherPresses.value += 1
                list.windows.removeAll { CFEqual($0, other.1) }
                return true
            }
            guard CFEqual(element, close) else { return false }
            pressed.value += 1
            if closeTakesEffect {
                list.windows.removeAll { CFEqual($0, editor) }
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
    let result = f.cleanup(baseline, runtime: runtime)
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
    let result = f.cleanup(baseline, runtime: runtime)
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
    let result = f.cleanup(baseline, runtime: runtime)
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
    let result = f.cleanup(baseline, runtime: runtime)
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
    let result = f.cleanup(nil, runtime: runtime)
    let editorCleanupObserved = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!editorCleanupObserved)
    #expect(f.pressed.value == 0)
}

// A window that is new since the baseline is not thereby the insert's editor.

/// An unrelated standard window (the Event List window, "이벤트 목록 열기" in Logic 13's 윈도우 menu)
/// that appears while the mount is polled, with its own close button.
private func unrelatedWindow(_ f: EditorFixture) -> (window: AXUIElement, close: AXUIElement) {
    let b = f.builder, window = b.element(40), close = b.element(41)
    b.setRole(window, kAXWindowRole as String)
    b.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
    b.setAttribute(window, kAXTitleAttribute as String, "NativeLogic13-9995.logicx - 이벤트 목록")
    b.setAttribute(window, kAXCloseButtonAttribute as String, close)
    b.setRole(close, kAXButtonRole as String)
    b.setAttribute(close, kAXWindowAttribute as String, window)
    return (window, close)
}

@Test func anUnrelatedWindowAppearingDuringMountPollingIsLeftOpenAndReported() throws {
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: true)
    let other = unrelatedWindow(f)
    let otherPresses = MutableBox(0)
    let runtime = f.runtime(
        closeTakesEffect: true, focusReturnsToMain: true,
        otherCloses: [(other.close, other.window)], otherPresses: otherPresses)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    f.list.windows.append(other.window)
    let result = f.cleanup(baseline, runtime: runtime)
    #expect(otherPresses.value == 0, "the unrelated window's close button was pressed")
    #expect(f.list.windows.contains { CFEqual($0, other.window) })
    #expect(f.pressed.value == 1, "the insert's own editor must still be closed")
    #expect(!f.list.windows.contains { CFEqual($0, f.editor) })
    #expect(result["post_insert_editor_windows_owned"] as? Int == 1)
    #expect(result["post_insert_unowned_windows_left_open"] as? Int == 1)
    #expect(result["post_insert_editor_cleanup_reason"] as? String == "unowned_window_left_open")
    let observed = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!observed)
    #expect(f.focusWrites.value == 0, "focus is not moved while a window this insert does not own is open")
}

@Test func aNewEditorOnTheTargetTrackNamingAnotherPluginIsNotClosed() throws {
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: true, editorPluginName: "Compressor")
    let runtime = f.runtime(closeTakesEffect: true, focusReturnsToMain: true)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    let result = f.cleanup(baseline, runtime: runtime)
    #expect(f.pressed.value == 0)
    #expect(result["post_insert_editor_windows_owned"] as? Int == 0)
    let observed = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!observed)
}

@Test func withoutABoundTargetTrackNoNewWindowIsClosed() throws {
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: true)
    let runtime = f.runtime(closeTakesEffect: true, focusReturnsToMain: true)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    let result = f.cleanup(baseline, runtime: runtime, trackName: nil)
    #expect(f.pressed.value == 0)
    #expect(result["post_insert_editor_cleanup_reason"] as? String == "target_track_unbound")
    let observed = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!observed)
}

@Test func anEditorWhoseTargetIsNoLongerCurrentIsNotClosed() throws {
    let f = EditorFixture(closeTakesEffect: true, focusReturnsToMain: true)
    let runtime = f.runtime(closeTakesEffect: true, focusReturnsToMain: true)
    let baseline = AccessibilityChannel.insertEditorWindowBaseline(runtime: runtime)
    f.openEditor()
    let result = f.cleanup(baseline, runtime: runtime, targetIsCurrent: { false })
    #expect(f.pressed.value == 0)
    let observed = try #require(result["post_insert_editor_cleanup_observed"] as? Bool)
    #expect(!observed)
}
