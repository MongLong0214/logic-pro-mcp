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
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
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
    #expect(!(AXLogicProElements.dialogPresent(runtime: runtime)))
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
    #expect(!(AXLogicProElements.dialogPresent(runtime: runtime)))
}

@Test func testDialogPresentFailsClosedWhenWindowsAreUnreadable() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { _, attribute in
            attribute == kAXWindowsAttribute as String ? .some(nil) : nil
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

// MARK: - #234 plugin-editor window classification

/// #234: Logic 12.3 tags plugin-editor windows with subrole `AXDialog` (title =
/// track name), which tripped the v3.7.2 modal guard on unrelated ops. A plugin
/// editor is distinguished from a true modal by Logic's own chrome — the window
/// exposes `kAXCloseButtonAttribute` plus, among its direct children, a
/// bypass-labeled toggle (`AXCheckBox` OR `AXButton`).
///
/// #381 narrowed the signature: a former conjunct additionally required a
/// compare- OR link-labeled toggle, but those labels were English-only, so a
/// localized (ko-KR) editor — bypass + close-button present — was misclassified
/// as blocking. The compare/link conjunct was dropped and the bypass conjunct
/// simultaneously TIGHTENED from substring to exact-field matching, because a
/// substring match is NOT modal-exclusive: the Bounce-in-Place dialog carries a
/// "Bypass Effect Plug-ins" checkbox whose text contains "bypass" (adversarial
/// review B1; pinned below by the bounce-dialog tests). These builders still
/// BUILD compare/link children (now ignored by the classifier) to keep
/// transcribing the live 12.3 dumps.
///
/// `buildPluginEditorWindow` transcribes the "Deluxe" live 12.3 dump
/// (`axdialog234.out` / PRD Appendix A); `buildFreshGainEditorWindow` models the
/// freshly-inserted shape (`axwhy234.out`). The `include*` / `chromeRole` knobs
/// let the fail-closed partial-chrome cases strip one conjunct at a time. The
/// close-button is set as the ATTRIBUTE (locale-neutral, the exact handle the
/// live probe closed the editor through), never as a `desc='close'` child.
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
    // Direct boolean (never `== false`): `#expect(!(bool))` is a dead
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

// MARK: - #381 localized plugin editor (compare/link conjunct dropped)

/// #381: a ko-KR plugin editor carries a localized bypass toggle (`바이패스`) and a
/// close-button attribute but NO English compare/link toggle. Pre-fix the
/// compare-OR-link conjunct was unmet → the editor was misclassified as a
/// blocking modal and unrelated ops (project.save, track.select) were refused
/// while it was open. Post-fix the bypass + close-button signature recognizes it
/// as an editor → non-blocking on BOTH public surfaces. FAILS pre-fix.
@Test func testKoLocalizedPluginEditorIsNonBlocking() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let window = builder.element(100)
    let closeButton = builder.element(101)
    let bypass = builder.element(102)
    let bodySlider = builder.element(103)

    builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "오디오 1")
    builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(window, kAXCloseButtonAttribute as String, closeButton)
    // Localized bypass toggle — the only chrome label present in a ko editor.
    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXTitleAttribute as String, "바이패스")
    builder.setAttribute(bodySlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setChildren(window, [bypass, bodySlider])

    builder.setAttribute(app, kAXWindowsAttribute as String, [window, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(!AXLogicProElements.dialogPresent(runtime: runtime))
    #expect(AXLogicProElements.blockingDialogInfo(runtime: runtime) == nil)
}

/// #381 safety: an AXDialog exposing a close-button attribute but NO bypass toggle
/// (a real sheet that happens to carry a close box) still fails the editor
/// signature → stays blocking. The bypass toggle, not the close-button alone,
/// carries the editor identity. Passes pre- and post-fix.
@Test func testCloseButtonWithoutBypassStaysBlocking() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let window = builder.element(100)
    let closeButton = builder.element(101)
    let okButton = builder.element(102)

    builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "Confirm")
    builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(window, kAXCloseButtonAttribute as String, closeButton)
    builder.setAttribute(okButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(okButton, kAXTitleAttribute as String, "OK")
    builder.setChildren(window, [okButton])

    builder.setAttribute(app, kAXWindowsAttribute as String, [window, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

/// #381 adversarial-review B1 pin: Logic's Bounce-in-Place dialog (reachable via
/// `edit.bounce_in_place`) is a GENUINE mutating modal that carries a "Bypass
/// Effect Plug-ins" checkbox — its text CONTAINS "bypass", so a SUBSTRING bypass
/// conjunct would classify it as a plugin editor whenever it also exposes a
/// close-button attribute (modeled here as the adversarial worst case; the
/// attribute's absence on real modals is live-unverified). The exact-field
/// matcher rejects the longer phrase → the dialog stays BLOCKING. FAILS on a
/// substring implementation.
@Test func testBounceInPlaceDialogWithBypassOptionStaysBlocking() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let dialog = builder.element(100)
    let closeButton = builder.element(101)
    let bypassOption = builder.element(102)
    let okButton = builder.element(103)
    let cancelButton = builder.element(104)

    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(dialog, kAXTitleAttribute as String, "Bounce Regions in Place")
    builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(dialog, kAXCloseButtonAttribute as String, closeButton)
    builder.setAttribute(bypassOption, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypassOption, kAXTitleAttribute as String, "Bypass Effect Plug-ins")
    builder.setAttribute(okButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(okButton, kAXTitleAttribute as String, "OK")
    builder.setAttribute(cancelButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancelButton, kAXTitleAttribute as String, "Cancel")
    builder.setChildren(dialog, [bypassOption, okButton, cancelButton])

    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

/// #381 B1 pin, ko locale: the localized bounce dialog's checkbox is a longer
/// phrase CONTAINING `바이패스` — a substring match on the ko variant would
/// misclassify it exactly like the EN case. Exact-field matching keeps it
/// BLOCKING. FAILS on a substring implementation.
@Test func testKoBounceInPlaceDialogStaysBlocking() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let dialog = builder.element(100)
    let closeButton = builder.element(101)
    let bypassOption = builder.element(102)
    let confirmButton = builder.element(103)

    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(dialog, kAXTitleAttribute as String, "리전을 제자리에 바운스")
    builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(dialog, kAXCloseButtonAttribute as String, closeButton)
    builder.setAttribute(bypassOption, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypassOption, kAXTitleAttribute as String, "이펙트 플러그인 바이패스")
    builder.setAttribute(confirmButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(confirmButton, kAXTitleAttribute as String, "바운스")
    builder.setChildren(dialog, [bypassOption, confirmButton])

    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

// MARK: - #381 T5 verified-parameter-write gate (pluginWindowMatch)

/// #381 M2: `pluginWindowMatch` (the T5 verified param-write gate) is the second
/// consumer of `isPluginEditorWindow`. The narrowed signature must let a
/// localized bypass-only editor through that gate too — a ko editor with the
/// right track-name title and a unique slider must resolve `.unique`, so the
/// localized verified-write path works. FAILS pre-fix (the editor fails the old
/// compare/link conjunct → never considered).
@Test func testPluginWindowMatchRecognizesLocalizedBypassOnlyEditor() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let editor = builder.element(100)
    let closeButton = builder.element(101)
    let bypass = builder.element(102)
    let gainSlider = builder.element(103)

    builder.setAttribute(editor, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(editor, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(editor, kAXTitleAttribute as String, "오디오 1")
    builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(editor, kAXCloseButtonAttribute as String, closeButton)
    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXTitleAttribute as String, "바이패스")
    builder.setAttribute(gainSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(gainSlider, kAXDescriptionAttribute as String, "Gain")
    builder.setChildren(editor, [bypass, gainSlider])

    builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    let match = AXLogicProElements.pluginWindowMatch(
        forTrackName: "오디오 1",
        matchingSliderDescription: "Gain",
        runtime: runtime
    )
    guard case .unique(let window) = match else {
        Issue.record("expected .unique, got \(match)")
        return
    }
    #expect(window == editor)
}

// MARK: - #405 Drummer Smart Controls docked pane

/// #405: a Drummer track's docked Smart Controls pane is tagged `AXDialog` with an
/// EMPTY title and NO close-button attribute (it is docked, not a floating
/// editor), so `isPluginEditorWindow` never recognized it and it fell through to
/// BLOCKING — refusing unrelated ops while the pane was open. The dedicated
/// Smart-Controls signature (AXDialog + empty title + a `Smart Controls` toggle)
/// classifies it as non-blocking on BOTH public surfaces. FAILS pre-fix.
private func buildSmartControlsPane(_ builder: FakeAXRuntimeBuilder, base: Int) -> AXUIElement {
    let window = builder.element(base)
    let padControls = builder.element(base + 1)
    let kitControls = builder.element(base + 2)
    let smartControls = builder.element(base + 3)
    let bodyGroup = builder.element(base + 4)

    builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "")
    builder.setAttribute(padControls, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(padControls, kAXTitleAttribute as String, "Pad Controls")
    builder.setAttribute(kitControls, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(kitControls, kAXTitleAttribute as String, "Kit Controls")
    builder.setAttribute(smartControls, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(smartControls, kAXTitleAttribute as String, "Smart Controls")
    builder.setAttribute(bodyGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setChildren(window, [padControls, kitControls, smartControls, bodyGroup])
    return window
}

@Test func testDmdSmartControlsPaneIsNonBlocking() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let pane = buildSmartControlsPane(builder, base: 100)

    builder.setAttribute(app, kAXWindowsAttribute as String, [pane, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(!AXLogicProElements.dialogPresent(runtime: runtime))
    #expect(AXLogicProElements.blockingDialogInfo(runtime: runtime) == nil)
}

/// #405 safety: the Smart-Controls exclusion requires an EMPTY title. A titled
/// AXDialog that happens to contain a `Smart Controls`-labeled toggle (a
/// hypothetical modal) still fails the empty-title conjunct → stays blocking, so
/// the recognizer cannot be tricked into excluding a titled modal.
@Test func testTitledDialogWithSmartControlsLabelStaysBlocking() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let window = builder.element(100)
    let smartControls = builder.element(101)

    builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "Delete Track?")
    builder.setAttribute(smartControls, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(smartControls, kAXTitleAttribute as String, "Smart Controls")
    builder.setChildren(window, [smartControls])

    builder.setAttribute(app, kAXWindowsAttribute as String, [window, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

/// #405 safety: an empty-title AXDialog WITHOUT a Smart-Controls toggle (a
/// title-less alert) is not a Smart Controls pane → stays blocking. The
/// Smart-Controls label, not the empty title alone, carries the exclusion.
@Test func testTitlelessDialogWithoutSmartControlsStaysBlocking() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let arrange = builder.element(2)
    let window = builder.element(100)
    let okButton = builder.element(101)
    let cancelButton = builder.element(102)

    builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "")
    builder.setAttribute(okButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(okButton, kAXTitleAttribute as String, "OK")
    builder.setAttribute(cancelButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancelButton, kAXTitleAttribute as String, "Cancel")
    builder.setChildren(window, [okButton, cancelButton])

    builder.setAttribute(app, kAXWindowsAttribute as String, [window, arrange])

    let runtime = builder.makeLogicRuntime(appElement: app)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}
