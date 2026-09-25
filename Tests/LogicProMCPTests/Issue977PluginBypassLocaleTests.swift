import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #977: three shared locators matched Logic's interface in fewer than ten languages.
///
/// Every case here feeds the product the string Logic SHIPS for that locale, spelled exactly as the
/// bundle spells it -- de `Bypass` with its capital, fr `Table de mixage` -- rather than a policy
/// member, because the defect was a member that equalled the row only after folding. The values are
/// the rows the three LabelSets cite (MAToolKit `bypass`, MAGUI `bypass`/`open`, Logic.framework
/// `Mixer#acc`), read from Logic 12.3 (6674), and all ten were read live on 2026-09-25
/// (`docs/observations/2026-09-25-977-*`). Italian shows `Mixer` where `Mixer#acc` reads `mixer`.
struct ShippedLocaleLabels: Sendable, CustomTestStringConvertible {
    let locale: String
    let editorBypass: String
    let slotBypass: String
    let slotOpen: String
    let mixer: String

    var testDescription: String { locale }

    static let all: [ShippedLocaleLabels] = [
        .init(locale: "de", editorBypass: "Bypass", slotBypass: "Umgehen", slotOpen: "geöffnet", mixer: "Mixer"),
        .init(locale: "en", editorBypass: "bypass", slotBypass: "bypass", slotOpen: "open", mixer: "Mixer"),
        .init(locale: "es", editorBypass: "desactivar", slotBypass: "desactivar", slotOpen: "abrir", mixer: "Mezclador"),
        .init(locale: "fr", editorBypass: "inactif", slotBypass: "inactif", slotOpen: "ouvrir", mixer: "Table de mixage"),
        .init(locale: "it", editorBypass: "ignora", slotBypass: "ignora", slotOpen: "apri", mixer: "mixer"),
        .init(locale: "ja", editorBypass: "バイパス", slotBypass: "バイパス", slotOpen: "開く", mixer: "ミキサー"),
        .init(locale: "ko", editorBypass: "바이패스", slotBypass: "바이패스", slotOpen: "열기", mixer: "믹서"),
        .init(locale: "pt", editorBypass: "bypass", slotBypass: "bypass", slotOpen: "abrir", mixer: "Mixer"),
        .init(locale: "zh_CN", editorBypass: "旁通", slotBypass: "旁通", slotOpen: "打开", mixer: "混音器"),
        .init(locale: "zh_TW", editorBypass: "略過", slotBypass: "略過", slotOpen: "打開", mixer: "混音器"),
    ]
}

@Suite("#977 plug-in bypass and Mixer locators in all ten locales")
struct Issue977PluginBypassLocaleTests {
    /// The editor's chrome as Logic 12.3 shows it: an `AXDialog` with a close-button attribute and
    /// a direct-child bypass toggle whose role flips between checkbox and button with focus.
    private func editorWindow(
        _ builder: FakeAXRuntimeBuilder,
        bypassLabel: String,
        bypassRole: String
    ) -> AXUIElement {
        let window = builder.element(100)
        let closeButton = builder.element(101)
        let bypass = builder.element(102)
        let body = builder.element(103)
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "Audio 1")
        builder.setAttribute(closeButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(window, kAXCloseButtonAttribute as String, closeButton)
        builder.setAttribute(bypass, kAXRoleAttribute as String, bypassRole)
        builder.setAttribute(bypass, kAXDescriptionAttribute as String, bypassLabel)
        builder.setAttribute(body, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setChildren(window, [bypass, body])
        return window
    }

    /// Before #977 the set held en/ko/ja only, so in es, fr, it and zh an open editor was a blocking
    /// modal and `project.save` refused with `preflight_blocking_dialog` -- measured in fr-FR.
    @Test("an open plug-in editor is not a blocking modal", arguments: ShippedLocaleLabels.all)
    func editorIsNotBlocking(labels: ShippedLocaleLabels) {
        for role in [kAXCheckBoxRole as String, kAXButtonRole as String] {
            let builder = FakeAXRuntimeBuilder()
            let app = builder.element(1)
            let arrange = builder.element(2)
            let editor = editorWindow(builder, bypassLabel: labels.editorBypass, bypassRole: role)
            builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])
            let runtime = builder.makeLogicRuntime(appElement: app)
            #expect(!AXLogicProElements.dialogPresent(runtime: runtime), "role=\(role)")
            #expect(AXLogicProElements.blockingDialogInfo(runtime: runtime) == nil, "role=\(role)")
        }
    }

    @Test("an open plug-in editor is enumerated as one", arguments: ShippedLocaleLabels.all)
    func editorIsEnumerated(labels: ShippedLocaleLabels) throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let editor = editorWindow(builder, bypassLabel: labels.editorBypass, bypassRole: kAXCheckBoxRole as String)
        builder.setAttribute(app, kAXWindowsAttribute as String, [editor])
        let windows = try AXLogicProElements.pluginEditorWindows(
            runtime: builder.makeLogicRuntime(appElement: app)
        ).get()
        #expect(windows.count == 1)
        #expect(windows.contains { CFEqual($0, editor) })
    }

    /// The shape the structural fallback does not accept (one action button, not two), so only the
    /// labels can recognise it.
    @Test("an occupied insert slot is recognised by its labels", arguments: ShippedLocaleLabels.all)
    func occupiedSlotByLabel(labels: ShippedLocaleLabels) {
        let builder = FakeAXRuntimeBuilder()
        let slot = builder.element(200)
        let bypass = builder.element(201)
        let open = builder.element(202)
        builder.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(bypass, kAXDescriptionAttribute as String, labels.slotBypass)
        builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(open, kAXDescriptionAttribute as String, labels.slotOpen)
        builder.setChildren(slot, [bypass, open])
        #expect(AXLogicProElements.isOccupiedPluginSlotElement(slot, runtime: builder.makeAXRuntime()))
    }

    /// The bypass toggle is an `AXButton` while its window is not key. It must never be ranked as a
    /// way to open the editor: pressing it bypasses the plug-in instead.
    @Test("a slot's bypass button is never ranked as its open control", arguments: ShippedLocaleLabels.all)
    func bypassButtonIsNotAnOpenControl(labels: ShippedLocaleLabels) throws {
        let builder = FakeAXRuntimeBuilder()
        let slot = builder.element(300)
        let bypass = builder.element(301)
        let open = builder.element(302)
        builder.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(bypass, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(bypass, kAXDescriptionAttribute as String, labels.slotBypass)
        builder.setActionNames(bypass, [kAXPressAction as String])
        builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(open, kAXDescriptionAttribute as String, labels.slotOpen)
        builder.setActionNames(open, [kAXPressAction as String])
        builder.setChildren(slot, [bypass, open])

        let ranked = AccessibilityChannel.rankedPluginSlotOpenControls(in: slot, runtime: builder.makeAXRuntime())

        // `try #require` and a plain Bool, never `optional == true`: that form passes whatever the
        // value in this toolchain (#92), and the Mixer case below passed on `nil` until it changed.
        let first = try #require(ranked.first)
        #expect(!ranked.contains { CFEqual($0.element, bypass) })
        #expect(CFEqual(first.element, open))
        #expect(first.rank == 0)
    }

    /// Before #977 the candidate was lowercased and tested for exact membership, so `table de
    /// mixage` never equalled the member `Table de mixage` and a French Logic had no Mixer.
    @Test("the docked Mixer is found by its localized description", arguments: ShippedLocaleLabels.all)
    func mixerIsFound(labels: ShippedLocaleLabels) throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(400)
        let layout = builder.element(401)
        let strip = builder.element(402)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [layout])
        builder.setAttribute(layout, kAXRoleAttribute as String, "AXLayoutArea")
        builder.setAttribute(layout, kAXDescriptionAttribute as String, labels.mixer)
        builder.setChildren(layout, [strip])
        builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)

        let found = try #require(AXLogicProElements.getMixerArea(runtime: builder.makeLogicRuntime(appElement: app)))

        #expect(CFEqual(found, layout))
    }
}
