@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

private func addPolicyMenuItem(
    _ builder: FakeAXRuntimeBuilder,
    _ id: Int,
    title: String,
    children: [AXUIElement] = []
) -> AXUIElement {
    let item = builder.element(id)
    builder.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(item, kAXTitleAttribute as String, title)
    builder.setChildren(item, children)
    return item
}

private func addPolicyElement(
    _ builder: FakeAXRuntimeBuilder,
    _ id: Int,
    role: String,
    title: String? = nil,
    children: [AXUIElement] = []
) -> AXUIElement {
    let item = builder.element(id)
    builder.setAttribute(item, kAXRoleAttribute as String, role)
    if let title {
        builder.setAttribute(item, kAXTitleAttribute as String, title)
    }
    builder.setChildren(item, children)
    return item
}

@Suite("AX locale policy")
struct AXLocalePolicyTests {
    @Test("localized label sets cover English and Korean without broad false positives")
    func labelSetMatching() {
        #expect(AXLocalePolicy.cancelButton.matches("Cancel"))
        #expect(AXLocalePolicy.cancelButton.matches("취소"))
        #expect(!AXLocalePolicy.cancelButton.matches("Do Not Save"))

        #expect(AXLocalePolicy.saveConfirmationButton.matches("Save"))
        #expect(AXLocalePolicy.saveConfirmationButton.matches("저장"))
        #expect(AXLocalePolicy.saveConfirmationButton.matches("확인"))
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("Don't Save"))

        #expect(AXLocalePolicy.undoMenuItemPrefix.matches("Undo Insert Plug-in", mode: .prefix))
        #expect(AXLocalePolicy.undoMenuItemPrefix.matches("실행 취소 플러그인 삽입", mode: .prefix))
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Redo Insert Plug-in", mode: .prefix))
    }

    @Test("#60 — matches(.contains/.prefix) is diacritic-SENSITIVE (no accent-folding widening)")
    func matchesIsDiacriticSensitive() {
        let set = AXLocalePolicy.LabelSet(
            canonical: "Inspector",
            variants: ["Inspector", "인스펙터"],
            rationale: "diacritic-sensitivity regression guard"
        )
        // Plain forms match — the real strings Logic emits.
        #expect(set.matches("Inspector", mode: .contains))
        #expect(set.matches("track inspector area", mode: .contains))
        #expect(set.matches("Inspector — Track", mode: .prefix))
        #expect(set.matches("인스펙터", mode: .contains))
        // Accented-Latin forms must NOT match. Pre-#60 the `.diacriticInsensitive`
        // option folded "ínspector" → "inspector" and matched, widening across
        // accented-Latin locales (French/Spanish/Portuguese Logic UIs) — the
        // exact locale collision #60 guards against. Aligns with containsAny (#122).
        #expect(!set.matches("ínspector", mode: .contains))
        #expect(!set.matches("Ínspector — Track", mode: .prefix))
        // Case-insensitivity is retained.
        #expect(set.matches("INSPECTOR", mode: .contains))
    }

    @Test("menu path lookup resolves English and Korean titles through one policy")
    func menuPathLookup() {
        let builder = FakeAXRuntimeBuilder()
        let menuBar = builder.element(1)
        let view = addPolicyMenuItem(builder, 2, title: "View")
        let showMixer = addPolicyMenuItem(builder, 3, title: "Show Mixer")
        let koreanWindow = addPolicyMenuItem(builder, 4, title: "윈도우")
        let hidePlugins = addPolicyMenuItem(builder, 5, title: "모든 플러그인 윈도우 가리기")
        builder.setChildren(menuBar, [view, koreanWindow])
        builder.setChildren(view, [showMixer])
        builder.setChildren(koreanWindow, [hidePlugins])

        let runtime = builder.makeAXRuntime()
        let viewMatch = AXLocalePolicy.findMenuBarItem(
            in: menuBar,
            matching: AXLocalePolicy.viewMenuBar,
            runtime: runtime
        )
        let windowMatch = AXLocalePolicy.findMenuBarItem(
            in: menuBar,
            matching: AXLocalePolicy.windowMenuBar,
            runtime: runtime
        )

        #expect(viewMatch == view)
        #expect(windowMatch == koreanWindow)
        #expect(AXLocalePolicy.findMenuItem(
            under: view,
            matching: AXLocalePolicy.showMixerMenuItem,
            runtime: runtime
        ) == showMixer)
        #expect(AXLocalePolicy.findMenuItem(
            under: koreanWindow,
            matching: AXLocalePolicy.hideAllPluginWindowsMenuItem,
            runtime: runtime
        ) == hidePlugins)
    }

    @Test("element matching checks title and description")
    func elementMatchingUsesTitleAndDescription() {
        let builder = FakeAXRuntimeBuilder()
        let titleButton = builder.element(20)
        let descriptionButton = builder.element(21)
        builder.setAttribute(titleButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(descriptionButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(titleButton, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(descriptionButton, kAXDescriptionAttribute as String, "취소")

        let runtime = builder.makeAXRuntime()

        #expect(AXLocalePolicy.elementMatches(titleButton, AXLocalePolicy.cancelButton, runtime: runtime))
        #expect(AXLocalePolicy.elementMatches(descriptionButton, AXLocalePolicy.cancelButton, runtime: runtime))
    }

    // MARK: - Deliberate Save/Cancel narrowing (contains -> exact)

    /// PR #98 narrowed the Save-As commit match from substring `contains`
    /// ("저장"/"Save") to whole-string `.exact`. These cases pin that the
    /// narrowing is deliberate: a decorated/superset title that the OLD
    /// `.contains` logic accepted must now be REJECTED, so a verified Save
    /// commit can never click the wrong button. State A on this path is gated
    /// only by `FileManager.fileExists`, so a missed match is an honest
    /// State C error, never a false success.
    @Test("save confirmation button narrows from contains to exact")
    func saveConfirmationButtonNarrowing() {
        // Exact canonical/variant titles still match (case-insensitive).
        #expect(AXLocalePolicy.saveConfirmationButton.matches("Save"))
        #expect(AXLocalePolicy.saveConfirmationButton.matches("저장"))
        #expect(AXLocalePolicy.saveConfirmationButton.matches("OK"))
        #expect(AXLocalePolicy.saveConfirmationButton.matches("확인"))

        // New case-insensitivity is intentional and documented.
        #expect(AXLocalePolicy.saveConfirmationButton.matches("SAVE"))
        #expect(AXLocalePolicy.saveConfirmationButton.matches("save"))

        // Deliberate narrowing: decorated/superset titles the OLD `.contains`
        // logic matched must now be rejected by `.exact`.
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("Save As…"))
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("Save…"))
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("Save As"))
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("저장하기"))
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("저장..."))

        // The "Don't Save" decoy is excluded regardless of mode.
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("Don't Save"))
    }

    /// The bare `OK`/`확인` variants are the broadest entries in
    /// `saveConfirmationButton`. They are kept deliberately because some
    /// localized Logic save panels commit via an "OK"/"확인" button rather
    /// than "Save". Pinning the positive bare-OK match and a realistic
    /// negative guard prevents an accidental change to the variant set going
    /// uncaught. The wrong-button risk is bounded: the Save path verifies
    /// via `FileManager.fileExists`, never by the click itself.
    @Test("save confirmation OK/확인 variants are deliberately broad but bounded")
    func saveConfirmationOKVariant() {
        #expect(AXLocalePolicy.saveConfirmationButton.matches("OK"))
        #expect(AXLocalePolicy.saveConfirmationButton.matches("확인"))

        // Decorated OK titles do not match under `.exact`.
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("OK, got it"))
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("확인하기"))
        // An unrelated dialog action is not mistaken for a Save commit.
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("Replace"))
    }

    /// Lock the Cancel button nil/empty/whitespace fail-closed guard and the
    /// whitespace-trimming contract. `matches` must reject garbage AX titles
    /// (nil, "", "   ") and must trim a real title before comparing.
    @Test("cancel button fail-closed guards and whitespace trimming")
    func cancelButtonGuards() {
        #expect(!AXLocalePolicy.cancelButton.matches(nil))
        #expect(!AXLocalePolicy.cancelButton.matches(""))
        #expect(!AXLocalePolicy.cancelButton.matches("   "))
        #expect(!AXLocalePolicy.cancelButton.matches("\n\t "))

        // Real titles with surrounding whitespace/newlines still match.
        #expect(AXLocalePolicy.cancelButton.matches(" Cancel "))
        #expect(AXLocalePolicy.cancelButton.matches("\t취소\n"))
        #expect(AXLocalePolicy.cancelButton.matches("CANCEL"))

        // Save button shares the same nil/empty guard.
        #expect(!AXLocalePolicy.saveConfirmationButton.matches(nil))
        #expect(!AXLocalePolicy.saveConfirmationButton.matches("   "))
    }

    /// Pin the `.prefix` mode's anchored, case-insensitive, **diacritic-SENSITIVE**
    /// matching used by the Undo rollback path. The anchored option means the
    /// label must be a true prefix; case is folded but accents are NOT (#60 —
    /// aligned with `containsAny`'s #122 sensitivity so accent-folding can't
    /// widen matching across accented-Latin locales).
    @Test("prefix mode is anchored, case-insensitive, diacritic-SENSITIVE")
    func prefixModeWidening() {
        // Real prefixes match (operation name follows the localized prefix).
        #expect(AXLocalePolicy.undoMenuItemPrefix.matches("Undo Insert Plug-in", mode: .prefix))
        #expect(AXLocalePolicy.undoMenuItemPrefix.matches("실행 취소 플러그인 삽입", mode: .prefix))

        // Case-insensitive prefix.
        #expect(AXLocalePolicy.undoMenuItemPrefix.matches("UNDO Insert Plug-in", mode: .prefix))

        // #60 — diacritic-SENSITIVE: an accented homograph must NOT match
        // (pre-#60 the folded "Ü" → "U" widened this).
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Ündo Insert Plug-in", mode: .prefix))

        // NFD vs NFC: the decomposed accented prefix likewise must NOT match
        // (canonical equivalence keeps NFC/NFD together, but "Ü" ≠ "U").
        let undoNFD = "U\u{0308}ndo Insert Plug-in" // U + combining diaeresis
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches(undoNFD, mode: .prefix))

        // Anchored: a label that appears mid-string is NOT a prefix match.
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Redo then Undo", mode: .prefix))
        #expect(!AXLocalePolicy.undoMenuItemPrefix.matches("Redo Insert Plug-in", mode: .prefix))
    }

    // MARK: - Go-to-Position dialog dismissal (.contains mode)

    /// The stale Go-to-Position dialog dismissal matches the window title with
    /// `.contains`. Pin that the live-verified real titles ("Go to Position",
    /// "위치로 이동") match even when wrapped in a window title, and that an
    /// unrelated window is rejected.
    @Test("go-to-position dialog title matches in contains mode")
    func goToPositionContainsMode() {
        #expect(AXLocalePolicy.goToPositionDialogTitle.matches("Go to Position", mode: .contains))
        #expect(AXLocalePolicy.goToPositionDialogTitle.matches("위치로 이동", mode: .contains))
        // Windowed title containing the phrase still matches.
        #expect(AXLocalePolicy.goToPositionDialogTitle.matches("Untitled — 위치로 이동", mode: .contains))
        #expect(AXLocalePolicy.goToPositionDialogTitle.matches("go to position", mode: .contains))

        // Unrelated window titles are rejected.
        #expect(!AXLocalePolicy.goToPositionDialogTitle.matches("Some Other Window", mode: .contains))
        // Deliberate narrowing: a bare "위치" without the full phrase is not a
        // recognized Go-to-Position dialog state.
        #expect(!AXLocalePolicy.goToPositionDialogTitle.matches("위치", mode: .contains))
        // nil/empty window titles fail closed.
        #expect(!AXLocalePolicy.goToPositionDialogTitle.matches(nil, mode: .contains))
        #expect(!AXLocalePolicy.goToPositionDialogTitle.matches("", mode: .contains))
    }

    // MARK: - Plugin format-leaf priority (live insert mutation path)

    /// Each entry in `pluginFormatLeafPriority` must resolve both its canonical
    /// (English) and Korean variant. A dropped variant would silently fail to
    /// select the right plugin format on a live insert.
    @Test("plugin format leaf priority resolves English and Korean variants")
    func pluginFormatLeafVariants() {
        let priority = AXLocalePolicy.pluginFormatLeafPriority
        // Guard against an accidental array truncation.
        #expect(priority.count == 4)

        for entry in priority {
            #expect(entry.matches(entry.canonical))
            let firstVariant = try! #require(entry.variants.first)
            #expect(entry.matches(firstVariant))
        }

        // Spot-check the canonical ordering by index.
        #expect(priority[0].matches("Stereo"))
        #expect(priority[0].matches("스테레오"))
        #expect(priority[1].matches("Mono"))
        #expect(priority[1].matches("모노"))
        #expect(priority[2].matches("Mono->Stereo"))
        #expect(priority[3].matches("Dual Mono"))
        #expect(priority[3].matches("듀얼 모노"))
    }

    /// Fixture priority test: when a submenu contains BOTH a Mono and a Stereo
    /// leaf, the first-match loop over `pluginFormatLeafPriority` must resolve
    /// to Stereo (higher priority wins over Mono). This pins the load-bearing
    /// ORDER that the insert driver (`preferredFormatLeaf`) depends on. The
    /// priority loop is replicated here (the production helper is private and
    /// requires CGEvent geometry); it exercises the exact same policy array
    /// and `elementMatches` resolution used live.
    @Test("plugin format leaf priority selects Stereo over Mono")
    func pluginFormatLeafPriorityStereoWins() {
        let builder = FakeAXRuntimeBuilder()
        // Intentionally place Mono BEFORE Stereo in child order to prove the
        // priority comes from the policy array, not menu order.
        let mono = addPolicyMenuItem(builder, 30, title: "Mono")
        let stereo = addPolicyMenuItem(builder, 31, title: "Stereo")
        let dualMono = addPolicyMenuItem(builder, 32, title: "Dual Mono")
        let submenu = builder.element(33)
        builder.setAttribute(submenu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setChildren(submenu, [mono, stereo, dualMono])
        let runtime = builder.makeAXRuntime()

        let items = AXHelpers.getChildren(submenu, runtime: runtime)
        let selected = selectFormatLeaf(in: items, runtime: runtime)
        #expect(selected == stereo)
    }

    /// Korean variants resolve through the same priority ordering: a submenu
    /// with 모노 and 스테레오 must still pick 스테레오 (Stereo).
    @Test("plugin format leaf priority selects Stereo over Mono in Korean")
    func pluginFormatLeafPriorityStereoWinsKorean() {
        let builder = FakeAXRuntimeBuilder()
        let mono = addPolicyMenuItem(builder, 40, title: "모노")
        let stereo = addPolicyMenuItem(builder, 41, title: "스테레오")
        let submenu = builder.element(42)
        builder.setAttribute(submenu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setChildren(submenu, [mono, stereo])
        let runtime = builder.makeAXRuntime()

        let items = AXHelpers.getChildren(submenu, runtime: runtime)
        let selected = selectFormatLeaf(in: items, runtime: runtime)
        #expect(selected == stereo)
    }

    /// Negative/equivalence guard: a submenu with ONLY the lowest-priority
    /// Dual Mono leaf still resolves to Dual Mono (lowest priority still
    /// selected when alone), guarding against accidental array truncation.
    @Test("plugin format leaf priority selects lone Dual Mono")
    func pluginFormatLeafPriorityLoneDualMono() {
        let builder = FakeAXRuntimeBuilder()
        let dualMono = addPolicyMenuItem(builder, 50, title: "Dual Mono")
        let submenu = builder.element(51)
        builder.setAttribute(submenu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setChildren(submenu, [dualMono])
        let runtime = builder.makeAXRuntime()

        let items = AXHelpers.getChildren(submenu, runtime: runtime)
        let selected = selectFormatLeaf(in: items, runtime: runtime)
        #expect(selected == dualMono)
    }

    // MARK: - Composed mutation-path equivalence (Undo / Save-As)

    /// Edit-menu Undo resolver: an enabled `Undo X` / `실행 취소 X` item must be
    /// found via the policy prefix lookup, and a disabled item's enablement
    /// can be read so the caller's `.disabled` branch fires. This pins the
    /// rollback wrapper control flow that pure-helper tests leave uncovered.
    @Test("edit-menu undo resolver finds enabled item and reads disabled state")
    func editUndoResolverEnablement() {
        let builder = FakeAXRuntimeBuilder()
        let undoItem = addPolicyMenuItem(builder, 60, title: "Undo Insert Plug-in")
        builder.setAttribute(undoItem, kAXEnabledAttribute as String, true)
        let koreanUndo = addPolicyMenuItem(builder, 61, title: "실행 취소 플러그인 삽입")
        builder.setAttribute(koreanUndo, kAXEnabledAttribute as String, false)
        let menu = builder.element(62)
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setChildren(menu, [undoItem])
        let editBarItem = addPolicyMenuItem(builder, 63, title: "Edit", children: [menu])

        let koreanMenu = builder.element(64)
        builder.setAttribute(koreanMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setChildren(koreanMenu, [koreanUndo])
        let koreanEditBarItem = addPolicyMenuItem(builder, 65, title: "편집", children: [koreanMenu])

        let runtime = builder.makeAXRuntime()

        let foundEnabled = AXLocalePolicy.findMenuItem(
            under: editBarItem,
            matching: AXLocalePolicy.undoMenuItemPrefix,
            mode: .prefix,
            runtime: runtime
        )
        #expect(foundEnabled == undoItem)
        let enabled: Bool = try! #require(
            AXHelpers.getAttribute(foundEnabled!, kAXEnabledAttribute as String, runtime: runtime)
        )
        #expect(enabled)

        let foundDisabled = AXLocalePolicy.findMenuItem(
            under: koreanEditBarItem,
            matching: AXLocalePolicy.undoMenuItemPrefix,
            mode: .prefix,
            runtime: runtime
        )
        #expect(foundDisabled == koreanUndo)
        let disabledFlag: Bool = try! #require(
            AXHelpers.getAttribute(foundDisabled!, kAXEnabledAttribute as String, runtime: runtime)
        )
        #expect(!disabledFlag)
    }

    /// Save-As commit equivalence: among a button set containing `Save` and a
    /// `Don't Save` decoy, the policy resolves the Save button and rejects the
    /// decoy. This pins the commit-button selection on the file-writing path.
    @Test("save-as commit resolves Save button and rejects Don't Save decoy")
    func saveAsCommitButtonSelection() {
        let builder = FakeAXRuntimeBuilder()
        let dontSave = addPolicyElement(builder, 70, role: kAXButtonRole as String, title: "Don't Save")
        let saveButton = addPolicyElement(builder, 71, role: kAXButtonRole as String, title: "Save")
        let cancelButton = addPolicyElement(builder, 72, role: kAXButtonRole as String, title: "Cancel")
        let sheet = builder.element(73)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setChildren(sheet, [dontSave, saveButton, cancelButton])
        let runtime = builder.makeAXRuntime()

        let buttons = AXHelpers.findAllDescendants(
            of: sheet,
            role: kAXButtonRole as String,
            runtime: runtime
        )
        let matched = buttons.first {
            AXLocalePolicy.elementMatches($0, AXLocalePolicy.saveConfirmationButton, runtime: runtime)
        }
        #expect(matched == saveButton)
        #expect(!AXLocalePolicy.elementMatches(dontSave, AXLocalePolicy.saveConfirmationButton, runtime: runtime))
        // The Cancel decoy is also not mistaken for a Save commit.
        #expect(!AXLocalePolicy.elementMatches(cancelButton, AXLocalePolicy.saveConfirmationButton, runtime: runtime))
    }

    // MARK: - findDescendant (live Cancel-button dismissal path)

    /// `findDescendant` is the role-scoped, depth-bounded helper that drives the
    /// Cancel-button lookup in `closeGoToPositionDialog`. Pin that it returns
    /// the nested Cancel BUTTON (not a same-titled non-button, not a deeper
    /// button beyond maxDepth) and respects maxDepth.
    @Test("findDescendant returns role-scoped, depth-bounded Cancel button")
    func findDescendantRoleAndDepth() {
        let builder = FakeAXRuntimeBuilder()
        // Same-titled non-button at shallow depth must be ignored (role filter).
        let decoyText = addPolicyElement(builder, 80, role: kAXStaticTextRole as String, title: "취소")
        // The real nested Cancel button lives at depth 3 inside two groups.
        let cancelButton = addPolicyElement(builder, 81, role: kAXButtonRole as String, title: "취소")
        let innerGroup = addPolicyElement(builder, 82, role: kAXGroupRole as String, children: [cancelButton])
        let outerGroup = addPolicyElement(
            builder, 83, role: kAXGroupRole as String, children: [decoyText, innerGroup]
        )
        let window = addPolicyElement(
            builder, 84, role: kAXWindowRole as String, children: [outerGroup]
        )
        let runtime = builder.makeAXRuntime()

        let found = AXLocalePolicy.findDescendant(
            of: window,
            role: kAXButtonRole as String,
            matching: AXLocalePolicy.cancelButton,
            maxDepth: 4,
            runtime: runtime
        )
        #expect(found == cancelButton)

        // maxDepth: 1 only reaches the window's direct children (the outer
        // group), so the nested button is out of range and nothing matches.
        let shallow = AXLocalePolicy.findDescendant(
            of: window,
            role: kAXButtonRole as String,
            matching: AXLocalePolicy.cancelButton,
            maxDepth: 1,
            runtime: runtime
        )
        #expect(shallow == nil)
    }

    // MARK: - Phase 2 (#60) read-only locator label sets

    /// `.exactStrict` mode preserves verbatim (no-trim) equality used by the
    /// control-bar / track-header structural locators. A title with surrounding
    /// whitespace must NOT match under `.exactStrict` (whereas `.exact` would).
    @Test("exactStrict matches verbatim and does not trim whitespace")
    func exactStrictNoTrim() {
        #expect(AXLocalePolicy.barSliderLabel.matches("bar", mode: .exactStrict))
        #expect(AXLocalePolicy.barSliderLabel.matches("마디", mode: .exactStrict))
        // Case-insensitive (the EN locator lowercased before comparing).
        #expect(AXLocalePolicy.barSliderLabel.matches("BAR", mode: .exactStrict))
        // No trimming: padded titles are rejected, preserving raw `==` behavior.
        #expect(!AXLocalePolicy.barSliderLabel.matches(" bar ", mode: .exactStrict))
        #expect(!AXLocalePolicy.barSliderLabel.matches("마디 ", mode: .exactStrict))
        // Empty / nil fail closed.
        #expect(!AXLocalePolicy.barSliderLabel.matches("", mode: .exactStrict))
        #expect(!AXLocalePolicy.barSliderLabel.matches(nil, mode: .exactStrict))
        // Unrelated token rejected.
        #expect(!AXLocalePolicy.barSliderLabel.matches("beat", mode: .exactStrict))
    }

    /// Transport control identification label sets (read-only) resolve EN+KO and
    /// reject unrelated descriptions. `containsAny` mirrors the original
    /// lowercased-substring control flow.
    @Test("transport control labels resolve English and Korean via containsAny")
    func transportControlLabels() {
        #expect(AXLocalePolicy.transportPlayControl.containsAny(in: "play"))
        #expect(AXLocalePolicy.transportPlayControl.containsAny(in: "재생"))
        #expect(!AXLocalePolicy.transportPlayControl.containsAny(in: "record"))

        #expect(AXLocalePolicy.transportRecordControl.containsAny(in: "record"))
        #expect(AXLocalePolicy.transportRecordControl.containsAny(in: "녹음"))
        #expect(!AXLocalePolicy.transportRecordControl.containsAny(in: "play"))

        #expect(AXLocalePolicy.transportCycleControl.containsAny(in: "cycle"))
        #expect(AXLocalePolicy.transportCycleControl.containsAny(in: "loop"))
        #expect(AXLocalePolicy.transportCycleControl.containsAny(in: "사이클"))
        #expect(!AXLocalePolicy.transportCycleControl.containsAny(in: "metronome"))

        #expect(AXLocalePolicy.transportMetronomeControl.containsAny(in: "metronome"))
        #expect(AXLocalePolicy.transportMetronomeControl.containsAny(in: "click"))
        #expect(AXLocalePolicy.transportMetronomeControl.containsAny(in: "메트로놈"))
        #expect(AXLocalePolicy.transportMetronomeControl.containsAny(in: "클릭"))
        #expect(!AXLocalePolicy.transportMetronomeControl.containsAny(in: "cycle"))
    }

    /// The record-arm exclusion tokens distinguish a per-track record-arm control
    /// from the transport Record button. Their presence must be detectable in
    /// both EN and KO so the negative guard fires.
    @Test("record-arm exclusion tokens resolve English and Korean")
    func recordArmExclusionLabels() {
        #expect(AXLocalePolicy.transportRecordArmExclusion.containsAny(in: "record arm"))
        #expect(AXLocalePolicy.transportRecordArmExclusion.containsAny(in: "녹음 활성화"))
        // A plain transport Record description does not trip the exclusion.
        #expect(!AXLocalePolicy.transportRecordArmExclusion.containsAny(in: "record"))
        #expect(!AXLocalePolicy.transportRecordArmExclusion.containsAny(in: "녹음"))
    }

    /// Tempo/position field labels (read-only text fields). The tempo FIELD set
    /// includes `bpm`; pin EN+KO resolution and a clean rejection.
    @Test("tempo and position field labels resolve English and Korean")
    func tempoAndPositionFieldLabels() {
        #expect(AXLocalePolicy.tempoFieldLabel.containsAny(in: "tempo"))
        #expect(AXLocalePolicy.tempoFieldLabel.containsAny(in: "bpm"))
        #expect(AXLocalePolicy.tempoFieldLabel.containsAny(in: "템포"))
        #expect(!AXLocalePolicy.tempoFieldLabel.containsAny(in: "position"))

        #expect(AXLocalePolicy.playheadPositionFieldLabel.containsAny(in: "position"))
        #expect(AXLocalePolicy.playheadPositionFieldLabel.containsAny(in: "재생헤드 위치"))
        #expect(!AXLocalePolicy.playheadPositionFieldLabel.containsAny(in: "tempo"))
    }

    /// The transport-extraction tempo SLIDER set must NOT include `bpm` (the
    /// historical `.contains` loop matched only tempo/템포). This pins the
    /// deliberate distinction from `tempoSliderLabel` (the exact slider locator,
    /// which DOES accept bpm). Mixing them up would widen the extraction loop.
    @Test("tempo slider contains-label excludes bpm but exact slider label keeps it")
    func tempoSliderLabelSplit() {
        // Read-only extraction loop: tempo/템포 only.
        #expect(AXLocalePolicy.tempoSliderContainsLabel.containsAny(in: "tempo"))
        #expect(AXLocalePolicy.tempoSliderContainsLabel.containsAny(in: "템포"))
        #expect(!AXLocalePolicy.tempoSliderContainsLabel.containsAny(in: "bpm"))

        // Exact locator (findTempoSlider): tempo/템포/bpm all match verbatim.
        #expect(AXLocalePolicy.tempoSliderLabel.matches("tempo", mode: .exactStrict))
        #expect(AXLocalePolicy.tempoSliderLabel.matches("템포", mode: .exactStrict))
        #expect(AXLocalePolicy.tempoSliderLabel.matches("bpm", mode: .exactStrict))
        #expect(!AXLocalePolicy.tempoSliderLabel.matches("position", mode: .exactStrict))
    }

    /// Control-bar / bar / beat slider locators resolve EN+KO verbatim and
    /// reject unrelated descriptions.
    @Test("control-bar and bar/beat slider labels resolve English and Korean")
    func controlBarAndSliderLabels() {
        #expect(AXLocalePolicy.controlBarGroupLabel.matches("control bar", mode: .exactStrict))
        #expect(AXLocalePolicy.controlBarGroupLabel.matches("컨트롤 막대", mode: .exactStrict))
        #expect(AXLocalePolicy.controlBarGroupLabel.matches("コントロールバー", mode: .exactStrict))
        #expect(!AXLocalePolicy.controlBarGroupLabel.matches("transport", mode: .exactStrict))

        #expect(AXLocalePolicy.barSliderLabel.matches("bar", mode: .exactStrict))
        #expect(AXLocalePolicy.barSliderLabel.matches("마디", mode: .exactStrict))

        #expect(AXLocalePolicy.beatSliderLabel.matches("beat", mode: .exactStrict))
        #expect(AXLocalePolicy.beatSliderLabel.matches("비트", mode: .exactStrict))
        #expect(!AXLocalePolicy.beatSliderLabel.matches("bar", mode: .exactStrict))

        // Mutation this rejects: change this exact group label to generic `position` (or add that
        // token as a variant), which would make an unrelated AXGroup eligible as the owner.
        #expect(AXLocalePolicy.playheadPositionGroupLabel.matches("Playhead Position", mode: .exactStrict))
        #expect(AXLocalePolicy.playheadPositionGroupLabel.matches("재생헤드 위치", mode: .exactStrict))
        #expect(!AXLocalePolicy.playheadPositionGroupLabel.matches("Position", mode: .exactStrict))
    }

    /// The metronome is the one Japanese transport label that is a compound word.
    /// Measured on a Japanese Logic build: the control bar checkbox reads
    /// `メトロノームクリック`, and `.exactStrict` matches nothing shorter — so a set carrying
    /// only the halves cannot find it. This asserts the whole string, not the halves.
    @Test("the Japanese metronome control is one compound label")
    func japaneseMetronomeIsACompoundLabel() {
        #expect(AXLocalePolicy.transportMetronomeControl.matches("メトロノームクリック", mode: .exactStrict))
        // The halves remain valid on surfaces that use them.
        #expect(AXLocalePolicy.transportMetronomeControl.matches("クリック", mode: .exactStrict))
        #expect(AXLocalePolicy.transportMetronomeControl.matches("メトロノーム", mode: .exactStrict))
        // Exactness is deliberate: a longer unrelated string must not match.
        #expect(!AXLocalePolicy.transportMetronomeControl.matches("メトロノームクリックを表示", mode: .exactStrict))
    }

    @Test("transport controls include actual Japanese Logic labels")
    func japaneseTransportLabels() {
        #expect(AXLocalePolicy.transportPlayControl.matches("再生"))
        #expect(AXLocalePolicy.transportRecordControl.matches("録音"))
        #expect(AXLocalePolicy.transportCycleControl.matches("サイクル"))
        #expect(AXLocalePolicy.transportMetronomeControl.matches("メトロノーム"))
        #expect(AXLocalePolicy.transportMetronomeControl.matches("クリック"))
    }

    /// Track-header Mute/Solo/Record button labels (read-only state extraction)
    /// resolve EN+KO via substring and reject the wrong control.
    @Test("track mute/solo/record button labels resolve English and Korean")
    func trackButtonLabels() {
        #expect(AXLocalePolicy.trackMuteButton.containsAny(in: "mute channel strip"))
        #expect(AXLocalePolicy.trackMuteButton.containsAny(in: "음소거"))
        #expect(!AXLocalePolicy.trackMuteButton.containsAny(in: "solo"))

        #expect(AXLocalePolicy.trackSoloButton.containsAny(in: "solo"))
        #expect(AXLocalePolicy.trackSoloButton.containsAny(in: "솔로"))
        #expect(!AXLocalePolicy.trackSoloButton.containsAny(in: "mute"))

        #expect(AXLocalePolicy.trackRecordButton.containsAny(in: "record"))
        #expect(AXLocalePolicy.trackRecordButton.containsAny(in: "rec"))
        #expect(AXLocalePolicy.trackRecordButton.containsAny(in: "녹음 활성화"))
        #expect(AXLocalePolicy.trackRecordButton.containsAny(in: "레코드 활성화"))
        #expect(!AXLocalePolicy.trackRecordButton.containsAny(in: "mute"))
    }

    /// The per-track record-enable AXCheckBox label set is matched VERBATIM
    /// (case-sensitive) at the call site via `labels.contains(desc)`. Pin the
    /// exact label tokens and ordering so the locator can never silently drift.
    @Test("record-enable checkbox labels are verbatim and ordered")
    func recordEnableCheckboxLabels() {
        let labels = AXLocalePolicy.trackRecordEnableCheckbox.labels
        #expect(labels == ["녹음 활성화", "Record Enable", "Record"])
        // Verbatim contains (the production call site uses `labels.contains(desc)`).
        #expect(labels.contains("녹음 활성화"))
        #expect(labels.contains("Record Enable"))
        #expect(labels.contains("Record"))
        // Case-sensitive: a lowercased English variant is NOT in the set.
        #expect(!labels.contains("record"))
        #expect(!labels.contains("record enable"))
    }

    /// The plugin Setting popup value label set is matched VERBATIM
    /// (case-sensitive substring) at the call site. Pin EN+KO tokens and order.
    @Test("setting popup value labels are verbatim and ordered")
    func settingPopupValueLabels() {
        let labels = AXLocalePolicy.settingPopupValue.labels
        #expect(labels == ["Preset", "프리셋", "Default", "기본"])
        #expect(labels.contains(where: { "#0 Preset 1".contains($0) }))
        #expect(labels.contains(where: { "프리셋 없음".contains($0) }))
        #expect(labels.contains(where: { "Default Setting".contains($0) }))
        #expect(labels.contains(where: { "기본 설정".contains($0) }))
        // Case-sensitive substring: lowercased English must not match.
        #expect(!labels.contains(where: { "preset".contains($0) }))
    }
}

/// Replicates the first-match priority loop from
/// `AccessibilityChannel.preferredFormatLeaf` (which is private and additionally
/// gated by CGEvent geometry) against a list of candidate menu items. Exercises
/// the exact same `AXLocalePolicy.pluginFormatLeafPriority` array and
/// `elementMatches` resolution used on the live insert path.
private func selectFormatLeaf(
    in items: [AXUIElement],
    runtime: AXHelpers.Runtime
) -> AXUIElement? {
    for labels in AXLocalePolicy.pluginFormatLeafPriority {
        if let match = items.first(where: {
            AXLocalePolicy.elementMatches($0, labels, runtime: runtime)
        }) {
            return match
        }
    }
    return items.first
}
