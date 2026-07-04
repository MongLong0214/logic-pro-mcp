@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

/// v3.1.1 (P1-2) — verify `mainWindow()` skips modal dialog windows
/// (subrole `AXDialog` / `AXSystemDialog`) and prefers the arrange window
/// (the one that owns the Track Headers group). Pre-3.1.1 the function
/// returned `kAXMainWindowAttribute` directly; macOS reports the topmost
/// dialog as the main window while it is up, so callers walking down from
/// it found no transport / no tracks and the StateCache wrote a phantom
/// "empty project" payload.

@Test func testMainWindowSkipsDialogWindows() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let dialog = builder.element(2)
    let arrange = builder.element(3)
    let trackHeadersGroup = builder.element(4)

    // Dialog window — must be skipped.
    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)

    // Arrange window — has Track Headers group descendant.
    builder.setChildren(arrange, [trackHeadersGroup])
    builder.setAttribute(trackHeadersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(trackHeadersGroup, "AXDescription" as String, "트랙 헤더")

    // Windows array exposes both. macOS would set kAXMainWindowAttribute to
    // the dialog (the modal sheet steals "main"); the new logic must prefer
    // the arrange window regardless.
    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, arrange])
    builder.setAttribute(app, kAXMainWindowAttribute as String, dialog)

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.mainWindow(runtime: runtime) == arrange)
}

@Test func testMainWindowSkipsSystemDialogWindows() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let bouncePanel = builder.element(2)
    let arrange = builder.element(3)
    let trackHeadersGroup = builder.element(4)

    // System dialog (e.g. macOS file-open panel routed through AppKit).
    builder.setAttribute(bouncePanel, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)

    builder.setChildren(arrange, [trackHeadersGroup])
    builder.setAttribute(trackHeadersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(trackHeadersGroup, "AXDescription" as String, "Track Headers")

    builder.setAttribute(app, kAXWindowsAttribute as String, [bouncePanel, arrange])
    builder.setAttribute(app, kAXMainWindowAttribute as String, bouncePanel)

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.mainWindow(runtime: runtime) == arrange)
}

@Test func testMainWindowPrefersLogic122TracksHeaderDescription() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(11)
    let floatingPane = builder.element(12)
    let arrange = builder.element(13)
    let trackHeadersGroup = builder.element(14)

    builder.setChildren(arrange, [trackHeadersGroup])
    builder.setAttribute(trackHeadersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(trackHeadersGroup, kAXDescriptionAttribute as String, "Tracks header")

    builder.setAttribute(app, kAXWindowsAttribute as String, [floatingPane, arrange])
    builder.setAttribute(app, kAXMainWindowAttribute as String, floatingPane)

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.mainWindow(runtime: runtime) == arrange)
}

@Test func testMainWindowPrefersLanguageNeutralTrackHeaderStructure() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(21)
    let floatingPane = builder.element(22)
    let arrange = builder.element(23)
    let trackHeadersGroup = builder.element(24)
    let trackHeader = builder.element(25)

    builder.setChildren(arrange, [trackHeadersGroup])
    builder.setAttribute(trackHeadersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(trackHeadersGroup, kAXDescriptionAttribute as String, "Localized track rail")
    builder.setChildren(trackHeadersGroup, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeadersGroup, kAXSelectedChildrenAttribute as String, [trackHeader])

    builder.setAttribute(app, kAXWindowsAttribute as String, [floatingPane, arrange])
    builder.setAttribute(app, kAXMainWindowAttribute as String, floatingPane)

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.mainWindow(runtime: runtime) == arrange)
}

@Test func testMainWindowFallsBackToFirstNonDialogWindow() {
    // No window carries the Track Headers group (e.g. Library detached
    // pane in front, arrange minimized). We still skip dialogs and return
    // the first non-dialog so downstream lookups have something to walk.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let dialog = builder.element(2)
    let libraryPane = builder.element(3)

    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    // libraryPane has no subrole — treated as a regular window.

    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, libraryPane])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.mainWindow(runtime: runtime) == libraryPane)
}

@Test func testMainWindowFallsBackToLegacyAttributeWhenNoWindowsArray() {
    // Test doubles that don't set kAXWindowsAttribute (every existing
    // AXLogicProElementsTests.swift case) must still work via the legacy
    // kAXMainWindowAttribute fallback.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let window = builder.element(2)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.mainWindow(runtime: runtime) == window)
}

@Test func testDialogPresentDetectsActiveModal() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let dialog = builder.element(2)
    let arrange = builder.element(3)

    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime) == true)
}

@Test func testBlockingDialogInfoReportsIdentityAndCancelRecovery() {
    // #190: a blocking dialog must be identified — title, role, owning window,
    // buttons, and a safe (Cancel-first) recovery action.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let dialog = builder.element(2)
    let arrange = builder.element(3)
    let cancelButton = builder.element(4)
    let saveButton = builder.element(5)

    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(dialog, kAXTitleAttribute as String, "Save")
    builder.setChildren(dialog, [cancelButton, saveButton])
    builder.setAttribute(cancelButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancelButton, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(saveButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(saveButton, kAXTitleAttribute as String, "Save")
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Demo - Tracks")
    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, arrange])
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)

    let runtime = builder.makeLogicRuntime(appElement: app)
    let info = AXLogicProElements.blockingDialogInfo(runtime: runtime)

    let resolved = try! #require(info)
    #expect(resolved.title == "Save")
    #expect(resolved.role == (kAXDialogSubrole as String))
    #expect(resolved.owningWindow == "Demo - Tracks")
    #expect(resolved.buttonTitles.contains("Cancel"))
    #expect(resolved.buttonTitles.contains("Save"))
    #expect(resolved.recoveryAction.contains("Cancel"))
}

@Test func testBlockingDialogInfoReturnsNilWhenNoDialog() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.blockingDialogInfo(runtime: runtime) == nil)
}

@Test func testDialogPresentReturnsFalseWhenNoDialogs() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime) == false)
}

@Test func testDialogPresentIgnoresKeyboardLayoutOverlayDialog() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let dialog = builder.element(2)
    let indicator = builder.element(3)
    let arrange = builder.element(4)

    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setChildren(dialog, [indicator])
    builder.setAttribute(indicator, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(indicator, kAXDescriptionAttribute as String, "com.apple.keylayout.ABC")
    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime) == false)
}

@Test func testDialogPresentReturnsFalseWhenNoWindowsExposed() {
    // No kAXWindowsAttribute set — treated as "no dialogs known".
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime) == false)
}

// MARK: - #234 plugin-editor window classification

/// #234: Logic 12.3 tags plugin-editor windows with subrole `AXDialog` (title =
/// track name), which tripped the v3.7.2 modal guard on unrelated ops. A plugin
/// editor is distinguished from a true modal by Logic's own chrome — the window
/// exposes `kAXCloseButtonAttribute` plus, among its direct children, a
/// bypass-labeled `AXCheckBox` AND a compare-OR-link-labeled `AXCheckBox`. This
/// "Deluxe" shape (bypass + compare) transcribes the live 12.3 dump
/// (`axdialog234.out` / PRD Appendix A); `buildFreshGainEditorWindow` models the
/// freshly-inserted shape (bypass + link, no compare — `axwhy234.out`). The
/// `include*` / `chromeRole` knobs let the fail-closed partial-chrome cases strip
/// one conjunct at a time. The close-button is set as the ATTRIBUTE (locale-
/// neutral, the exact handle the live probe closed the editor through), never as
/// a `desc='close'` child.
private func buildPluginEditorWindow(
    _ builder: FakeAXRuntimeBuilder,
    base: Int,
    includeBypass: Bool = true,
    includeCompare: Bool = true,
    includeLink: Bool = false,
    includeClose: Bool = true,
    chromeRole: String = kAXCheckBoxRole as String
) -> AXUIElement {
    let window = builder.element(base)
    let closeButton = builder.element(base + 1)
    let bypass = builder.element(base + 2)
    let compare = builder.element(base + 3)
    let bodySlider = builder.element(base + 4)
    let bodyField = builder.element(base + 5)
    let link = builder.element(base + 6)

    builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "Deluxe Classic")
    if includeClose {
        builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(closeButton, kAXDescriptionAttribute as String, "close")
        builder.setAttribute(window, kAXCloseButtonAttribute as String, closeButton)
    }

    var children: [AXUIElement] = []
    if includeLink {
        builder.setAttribute(link, kAXRoleAttribute as String, chromeRole)
        builder.setAttribute(link, kAXDescriptionAttribute as String, "link")
        children.append(link)
    }
    if includeBypass {
        builder.setAttribute(bypass, kAXRoleAttribute as String, chromeRole)
        builder.setAttribute(bypass, kAXTitleAttribute as String, " ")
        builder.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
        children.append(bypass)
    }
    if includeCompare {
        builder.setAttribute(compare, kAXRoleAttribute as String, chromeRole)
        builder.setAttribute(compare, kAXTitleAttribute as String, "Compare")
        builder.setAttribute(compare, kAXDescriptionAttribute as String, "compare")
        children.append(compare)
    }
    // Plugin body (evidence — never conjuncts).
    builder.setAttribute(bodySlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(bodyField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    children.append(contentsOf: [bodySlider, bodyField])

    builder.setChildren(window, children)
    return window
}

/// #234: a freshly-inserted plugin's auto-opened editor (live 12.3 Gain evidence,
/// `axwhy234.out` / `axwhy234b.out`, 2026-07-05): `AXDialog title='Audio 1'`,
/// `kAXCloseButtonAttribute` present, direct children = close/toolbar buttons, a
/// `link` checkbox, a `view` menu-button, a `bypass` toggle, a popup, a group, and
/// two static texts — crucially NO `compare` checkbox (Compare chrome appears only
/// once the plugin has preset/edit state). The toggle ROLE flaps with window focus
/// (checkbox when key, button when not): `bypassRole` models both. This is the
/// single most common editor state in the verified apply-back flow, so it must
/// classify non-blocking regardless of focus.
private func buildFreshGainEditorWindow(
    _ builder: FakeAXRuntimeBuilder,
    base: Int,
    bypassRole: String = kAXCheckBoxRole as String
) -> AXUIElement {
    let window = builder.element(base)
    let closeButton = builder.element(base + 1)
    let toolbarButton = builder.element(base + 2)
    let link = builder.element(base + 3)
    let viewMenu = builder.element(base + 4)
    let bypass = builder.element(base + 5)
    let popup = builder.element(base + 6)
    let group = builder.element(base + 7)
    let staticA = builder.element(base + 8)
    let staticB = builder.element(base + 9)

    builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "Audio 1")
    builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(closeButton, kAXDescriptionAttribute as String, "close")
    builder.setAttribute(window, kAXCloseButtonAttribute as String, closeButton)

    builder.setAttribute(toolbarButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(toolbarButton, kAXDescriptionAttribute as String, "toolbar")
    builder.setAttribute(link, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(link, kAXDescriptionAttribute as String, "link")
    builder.setAttribute(viewMenu, kAXRoleAttribute as String, kAXMenuButtonRole as String)
    builder.setAttribute(viewMenu, kAXTitleAttribute as String, "51%")
    builder.setAttribute(viewMenu, kAXDescriptionAttribute as String, "view")
    builder.setAttribute(bypass, kAXRoleAttribute as String, bypassRole)
    builder.setAttribute(bypass, kAXTitleAttribute as String, " ")
    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
    builder.setAttribute(popup, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
    builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(staticA, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(staticB, kAXRoleAttribute as String, kAXStaticTextRole as String)

    builder.setChildren(window, [closeButton, toolbarButton, link, viewMenu, bypass, popup, group, staticA, staticB])
    return window
}

/// Which conjunct(s) a partial-chrome variant withholds (AC-4.4).
/// Internal (not `private`) so the parameterized `@Test` below can name it.
struct PartialChromeVariant: Sendable {
    let includeBypass: Bool
    let includeCompare: Bool
    let includeLink: Bool
    let includeClose: Bool
    let chromeRole: String
    let name: String
}

@Test func testDialogPresentFalseWithOnlyPluginEditorOpen() {
    // AC-4.1: a standalone plugin-editor window (full chrome signature) is not
    // a blocking modal.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let editor = buildPluginEditorWindow(builder, base: 100)

    builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    // Direct boolean (never `== false`): `#expect(bool == false)` is a dead
    // assertion in this toolchain (repo issue #92).
    #expect(!AXLogicProElements.dialogPresent(runtime: runtime))
}

@Test func testBlockingDialogInfoNilWithPluginEditor() {
    // AC-4.1: the same window yields no blocking-dialog identity.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let editor = buildPluginEditorWindow(builder, base: 100)

    builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.blockingDialogInfo(runtime: runtime) == nil)
}

@Test func testSaveSheetStillBlocking() {
    // AC-4.2: a true save sheet (AXDialog, Save/Cancel, no close attribute, no
    // plugin chrome) stays blocking. Pin — passes pre-fix.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let sheet = builder.element(2)
    let saveButton = builder.element(3)
    let cancelButton = builder.element(4)
    let arrange = builder.element(5)

    builder.setAttribute(sheet, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(sheet, kAXTitleAttribute as String, "Save")
    builder.setChildren(sheet, [saveButton, cancelButton])
    builder.setAttribute(saveButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(saveButton, kAXTitleAttribute as String, "Save")
    builder.setAttribute(cancelButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancelButton, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(app, kAXWindowsAttribute as String, [sheet, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

@Test func testSystemDialogStillBlocking() {
    // AC-4.2: an AXSystemDialog is not an editor (the editor conjunct requires
    // subrole AXDialog) and stays blocking. Pin — passes pre-fix.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let systemDialog = builder.element(2)
    let arrange = builder.element(3)

    builder.setAttribute(systemDialog, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)
    builder.setAttribute(app, kAXWindowsAttribute as String, [systemDialog, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

@Test(arguments: [
    // bypass present (checkbox) but NEITHER compare NOR link → chrome branch unmet.
    PartialChromeVariant(
        includeBypass: true, includeCompare: false, includeLink: false, includeClose: true,
        chromeRole: kAXCheckBoxRole as String, name: "bypass checkbox without companion"
    ),
    // same, bypass as a BUTTON — the pin must hold in either toggle role form.
    PartialChromeVariant(
        includeBypass: true, includeCompare: false, includeLink: false, includeClose: true,
        chromeRole: kAXButtonRole as String, name: "bypass button without companion"
    ),
    // link (button) but no bypass → bypass conjunct unmet.
    PartialChromeVariant(
        includeBypass: false, includeCompare: false, includeLink: true, includeClose: true,
        chromeRole: kAXButtonRole as String, name: "link button without bypass"
    ),
    // link+compare (checkbox) but no bypass → bypass conjunct unmet.
    PartialChromeVariant(
        includeBypass: false, includeCompare: true, includeLink: true, includeClose: true,
        chromeRole: kAXCheckBoxRole as String, name: "link+compare without bypass"
    ),
    // full chrome as BUTTONS but NO close-button attribute → close conjunct unmet
    // (valid toggle role, so this proves the close attribute is still required).
    PartialChromeVariant(
        includeBypass: true, includeCompare: true, includeLink: true, includeClose: false,
        chromeRole: kAXButtonRole as String, name: "full button chrome without close attribute"
    ),
    // right labels on genuinely NON-toggle roles (static text) → no matching
    // AXCheckBox/AXButton children. AXButton is now a valid toggle role, so the
    // wrong-role pin must use a role the matcher never scans.
    PartialChromeVariant(
        includeBypass: true, includeCompare: true, includeLink: true, includeClose: true,
        chromeRole: kAXStaticTextRole as String, name: "labels on non-toggle roles"
    ),
])
func testPartialChromeStaysBlocking(_ variant: PartialChromeVariant) {
    // AC-4.4: any window matching only part of the chrome signature stays
    // blocking (fail-closed), whether the toggles are checkboxes or buttons. Pin —
    // every variant is an AXDialog missing a required conjunct, so it stays
    // blocking both pre- and post-fix.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let editor = buildPluginEditorWindow(
        builder,
        base: 100,
        includeBypass: variant.includeBypass,
        includeCompare: variant.includeCompare,
        includeLink: variant.includeLink,
        includeClose: variant.includeClose,
        chromeRole: variant.chromeRole
    )

    builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(
        AXLogicProElements.dialogPresent(runtime: runtime),
        "\(variant.name) must stay blocking"
    )
}

@Test func testFreshPluginEditorWithoutCompareIsNonBlocking() {
    // #234 live gap (axwhy234.out): a freshly-inserted plugin's editor exposes
    // link + bypass but NO compare. The signature's compare-OR-link branch must
    // still recognize it as a plugin editor → non-blocking on BOTH public
    // surfaces. FAILS pre-fix (compare-only signature classifies it blocking).
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let editor = buildFreshGainEditorWindow(builder, base: 100)

    builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(!AXLogicProElements.dialogPresent(runtime: runtime))
    #expect(AXLogicProElements.blockingDialogInfo(runtime: runtime) == nil)
}

@Test func testUnfocusedFreshGainEditorIsNonBlocking() {
    // #234 v2 live gap (axwhy234b.out, same 'Audio 1' window minutes apart): the
    // editor's toggle chrome role-flaps with window focus — the bypass toggle is
    // an AXButton (not AXCheckBox) while the editor is NOT key. The matcher must
    // scan AXCheckBox|AXButton toggles or it re-refuses project.save. FAILS pre-fix
    // (checkbox-only filter misses the AXButton bypass → classified blocking).
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let editor = buildFreshGainEditorWindow(builder, base: 100, bypassRole: kAXButtonRole as String)

    builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(!AXLogicProElements.dialogPresent(runtime: runtime))
    #expect(AXLogicProElements.blockingDialogInfo(runtime: runtime) == nil)
}

@Test func testEditorPlusRealDialogStillReportsDialog() {
    // AC-4.1 + regression: an editor AND a true save sheet are both open. The
    // real modal must still be reported (not masked by the editor). The sheet is
    // first in window order so this also passes pre-fix (both AXDialog → the
    // sheet is the first blocking window either way).
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let sheet = builder.element(2)
    let cancelButton = builder.element(3)
    let saveButton = builder.element(4)
    let arrange = builder.element(5)
    let editor = buildPluginEditorWindow(builder, base: 100)

    builder.setAttribute(sheet, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(sheet, kAXTitleAttribute as String, "Save")
    builder.setChildren(sheet, [cancelButton, saveButton])
    builder.setAttribute(cancelButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancelButton, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(saveButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(saveButton, kAXTitleAttribute as String, "Save")
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Untitled 54 - Tracks")
    builder.setAttribute(app, kAXWindowsAttribute as String, [sheet, editor, arrange])
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
    let info = AXLogicProElements.blockingDialogInfo(runtime: runtime)
    let resolved = try! #require(info)
    #expect(resolved.title == "Save")
    #expect(resolved.buttonTitles.contains("Cancel"))
    #expect(resolved.buttonTitles.contains("Save"))
}
