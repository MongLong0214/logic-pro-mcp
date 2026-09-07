import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #60 (Phase 4): the remaining read-only classifier token bags — mixer /
/// inspector / channel-strip / plugin-slot (surface #3) and region /
/// track-content / track-type (surface #5) — are centralized into
/// `AXLocalePolicy` instead of inline literals. These tests (1) pin each new
/// LabelSet to the EXACT token set the inline code carried (the behavior-
/// preservation guard — any dropped/changed token fails here), (2) check the
/// EN+KO match semantics, and (3) drive the accessible classifiers end-to-end
/// in both locales. None of these gate a State-A success.
@Suite("Issue60 locale phase 4 classifier bags")
struct Issue60LocalePhase4Tests {

    // MARK: - Token-coverage guard (each bag == its original inline token list)

    @Test("every Phase 4 LabelSet carries exactly its original inline tokens")
    func bagsPreserveOriginalTokens() {
        let cases: [(String, [String], Set<String>)] = [
            ("mixerInspectorContext", AXLocalePolicy.mixerInspectorContext.labels, ["inspector", "인스펙터"]),
            ("mixerNamedElement", AXLocalePolicy.mixerNamedElement.labels, ["mixer", "믹서"]),
            ("sliderSendHint", AXLocalePolicy.sliderSendHint.labels, ["send", "센드"]),
            ("sliderZoomHint", AXLocalePolicy.sliderZoomHint.labels, ["zoom", "확대"]),
            ("sliderVolumeHint", AXLocalePolicy.sliderVolumeHint.labels, ["volume", "fader", "볼륨", "ボリューム"]),
            ("sliderPanHint", AXLocalePolicy.sliderPanHint.labels, ["pan", "panning", "패닝", "밸런스", "パン"]),
            ("pluginBypassControl", AXLocalePolicy.pluginBypassControl.labels, ["bypass", "바이패스", "バイパス"]),
            ("pluginOpenOrListControl", AXLocalePolicy.pluginOpenOrListControl.labels, ["open", "열기", "list", "목록", "開く"]),
            ("pluginAutomationLabelExact", AXLocalePolicy.pluginAutomationLabelExact.labels, ["읽기, 오토메이션이 활성화됨", "read"]),
            ("pluginAutomationLabelSubstring", AXLocalePolicy.pluginAutomationLabelSubstring.labels, ["automation", "오토메이션"]),
            ("audioPluginSlotLabel", AXLocalePolicy.audioPluginSlotLabel.labels, ["audio plug-in", "audio effect", "오디오 플러그인", "오디오 이펙트", "オーディオプラグイン"]),
            ("sendOrIOControlLabel", AXLocalePolicy.sendOrIOControlLabel.labels, ["send", "센드", "input", "output", "입력", "출력"]),
            ("nonInsertButtonText", AXLocalePolicy.nonInsertButtonText.labels, [
                "send", "센드", "input", "입력", "output", "출력", "group", "그룹",
                "channel mode", "채널 모드", "eq", "setting", "설정",
                "gain reduction", "게인 축소", "mute", "음소거", "solo", "record", "녹음",
                "monitor", "모니터링", "volume", "볼륨", "fader", "페이더",
                "pan", "패닝", "밸런스",
            ]),
            ("headerPanHint", AXLocalePolicy.headerPanHint.labels, ["pan", "팬", "밸런스", "パン"]),
            ("trackHeadersDescription", AXLocalePolicy.trackHeadersDescription.labels, ["track headers", "track header", "tracks header", "tracks headers", "트랙 헤더"]),
            ("projectPickerWindow", AXLocalePolicy.projectPickerWindow.labels, ["프로젝트 선택", "choose a project", "choose project", "new from template"]),
            ("transportTextFieldHint", AXLocalePolicy.transportTextFieldHint.labels, ["tempo", "bpm", "position", "템포", "재생헤드 위치"]),
            ("trackContentExplicit", AXLocalePolicy.trackContentExplicit.labels, ["트랙 콘텐츠", "track content", "track contents", "tracks content", "tracks contents", "トラックコンテンツ"]),
            ("trackContentGeneric", AXLocalePolicy.trackContentGeneric.labels, ["콘텐츠", "content", "contents"]),
            ("regionKindDrummer", AXLocalePolicy.regionKindDrummer.labels, ["drummer", "session player", "드러머", "세션 플레이어"]),
            ("regionKindMidi", AXLocalePolicy.regionKindMidi.labels, ["midi"]),
            ("regionKindAudio", AXLocalePolicy.regionKindAudio.labels, ["audio", "오디오"]),
            // `リージョン` added 2026-09-06, measured from the ja-JP arrange-regions census. Not
            // drift: without it `AccessibilityChannel+Regions.swift:244` classified every Japanese
            // region as NOT a region, so `get_regions` returned an empty enumeration with no error
            // while a region was on screen — `nonRegion: 1, returned_count: 0` on four live heads
            // against `nonRegion: 0` for the same project in English.
            ("regionHelpKeyword", AXLocalePolicy.regionHelpKeyword.labels, ["region", "리전", "リージョン"]),
            // Japanese added 2026-09-07 (#778). Every one was READ, not translated: the ja-JP and
            // en-US navigation-free censuses of 2026-09-05 walk the same surfaces in the same
            // order, 1005 of 1031 rows align as matching blocks, and the aligned ja-JP row is the
            // label. Each is backed by the element it was read on — `パン` and `ボリューム` off
            // AXSlider descriptions, `バイパス` off an insert slot's checkbox, `オフ` off the
            // inspector's automation popup — and the live harness passed on a Japanese Logic at
            // the head that added them.
        ]
        for (name, labels, expected) in cases {
            #expect(Set(labels) == expected, "\(name) token drift: \(Set(labels).symmetricDifference(expected))")
        }
    }

    @Test("every Phase 4 classifier bag carries at least one Korean variant")
    func everyBagHasKorean() {
        let bags: [(String, AXLocalePolicy.LabelSet)] = [
            ("mixerInspectorContext", AXLocalePolicy.mixerInspectorContext),
            ("mixerNamedElement", AXLocalePolicy.mixerNamedElement),
            ("sliderSendHint", AXLocalePolicy.sliderSendHint),
            ("sliderZoomHint", AXLocalePolicy.sliderZoomHint),
            ("sliderVolumeHint", AXLocalePolicy.sliderVolumeHint),
            ("sliderPanHint", AXLocalePolicy.sliderPanHint),
            ("pluginBypassControl", AXLocalePolicy.pluginBypassControl),
            ("pluginOpenOrListControl", AXLocalePolicy.pluginOpenOrListControl),
            ("audioPluginSlotLabel", AXLocalePolicy.audioPluginSlotLabel),
            ("sendOrIOControlLabel", AXLocalePolicy.sendOrIOControlLabel),
            ("headerPanHint", AXLocalePolicy.headerPanHint),
            ("trackHeadersDescription", AXLocalePolicy.trackHeadersDescription),
            ("projectPickerWindow", AXLocalePolicy.projectPickerWindow),
            ("transportTextFieldHint", AXLocalePolicy.transportTextFieldHint),
            ("trackContentExplicit", AXLocalePolicy.trackContentExplicit),
            ("trackContentGeneric", AXLocalePolicy.trackContentGeneric),
            ("regionKindDrummer", AXLocalePolicy.regionKindDrummer),
            ("regionKindAudio", AXLocalePolicy.regionKindAudio),
            ("regionHelpKeyword", AXLocalePolicy.regionHelpKeyword),
        ]
        for (name, bag) in bags {
            let hasKorean = bag.labels.contains { $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
            #expect(hasKorean, "\(name) must carry a Korean variant")
        }
    }

    // MARK: - Match semantics (EN + KO), mirroring the call-site usage

    @Test("containsAny matches EN + KO and rejects unrelated text (classifier semantics)")
    func containsAnySemantics() {
        #expect(AXLocalePolicy.mixerInspectorContext.containsAny(in: "track inspector area"))
        #expect(AXLocalePolicy.mixerInspectorContext.containsAny(in: "그룹 인스펙터"))
        #expect(!AXLocalePolicy.mixerInspectorContext.containsAny(in: "mixer area"))

        #expect(AXLocalePolicy.regionKindDrummer.containsAny(in: "drummer track 1"))
        #expect(AXLocalePolicy.regionKindDrummer.containsAny(in: "세션 플레이어 리전"))
        #expect(!AXLocalePolicy.regionKindDrummer.containsAny(in: "audio region"))

        #expect(AXLocalePolicy.regionHelpKeyword.containsAny(in: "Audio Region starts at bar 5"))
        #expect(AXLocalePolicy.regionHelpKeyword.containsAny(in: "리전은 5마디에서 시작"))
        // Verbatim from the ja-JP arrange-regions census of 2026-09-05 — the string Logic actually
        // puts on a region's AXHelp, not a translation of the English one.
        #expect(AXLocalePolicy.regionHelpKeyword.containsAny(
            in: "リージョンの開始位置は1 bar 、終了位置は2 小節 です, MIDIリージョン. "
                + "MIDIノートおよびコントローライベントが含まれています。"))
        #expect(!AXLocalePolicy.regionHelpKeyword.containsAny(in: "marker at bar 5"))

        #expect(AXLocalePolicy.pluginBypassControl.containsAny(in: "bypass"))
        #expect(AXLocalePolicy.pluginBypassControl.containsAny(in: "바이패스 버튼"))
        #expect(!AXLocalePolicy.pluginBypassControl.containsAny(in: "open plugin window"))
    }

    @Test("containsAny is diacritic-SENSITIVE, mirroring the inline String.contains it replaced")
    func containsAnyIsDiacriticSensitive() {
        // Plain forms match (the actual EN/KO strings Logic emits).
        #expect(AXLocalePolicy.mixerInspectorContext.containsAny(in: "inspector"))
        #expect(AXLocalePolicy.sliderSendHint.containsAny(in: "send level"))
        #expect(AXLocalePolicy.transportTextFieldHint.containsAny(in: "tempo"))
        // Accented-Latin forms must NOT match — folding them would widen matching
        // beyond the original `text.contains(token)` and misclassify in accented
        // locales (French/Spanish/Portuguese Logic UIs).
        #expect(!AXLocalePolicy.mixerInspectorContext.containsAny(in: "ínspector"))
        #expect(!AXLocalePolicy.sliderSendHint.containsAny(in: "sénd"))
        #expect(!AXLocalePolicy.transportTextFieldHint.containsAny(in: "témpo"))
        #expect(!AXLocalePolicy.pluginBypassControl.containsAny(in: "bypáss"))
        // Case-insensitivity is retained (needed for the raw-help region site).
        #expect(AXLocalePolicy.regionHelpKeyword.containsAny(in: "Audio Region at bar 5"))
        // Korean canonical matching is preserved.
        #expect(AXLocalePolicy.regionKindDrummer.containsAny(in: "세션 플레이어 리전"))
    }

    @Test("mixerNamedElement exact-equality semantics (normalized lowercase)")
    func mixerNamedElementExact() {
        // Mirrors the call site: candidate is trimmed + lowercased, then == label.
        #expect(AXLocalePolicy.mixerNamedElement.labels.contains("mixer"))
        #expect(AXLocalePolicy.mixerNamedElement.labels.contains("믹서"))
        #expect(!AXLocalePolicy.mixerNamedElement.labels.contains("mixer area"))
    }

    @Test("trackContent normalized-exact bags: explicit vs generic do not overlap")
    func trackContentExactness() {
        #expect(AXLocalePolicy.trackContentExplicit.labels.contains("트랙 콘텐츠"))
        #expect(AXLocalePolicy.trackContentExplicit.labels.contains("track content"))
        #expect(AXLocalePolicy.trackContentGeneric.labels.contains("콘텐츠"))
        #expect(AXLocalePolicy.trackContentGeneric.labels.contains("content"))
        #expect(Set(AXLocalePolicy.trackContentExplicit.labels).isDisjoint(with: Set(AXLocalePolicy.trackContentGeneric.labels)))
    }

    /// The strings Logic actually shows, put through the normalization
    /// `AccessibilityChannel+Regions.normalizeRegionGroupDescription` applies
    /// before the lookup. Asserting membership of the stored form only would
    /// pass while the product still failed: the stored English form is
    /// lowercase and Logic shows `Tracks contents`, and it is the normalization
    /// that closes that gap. Both strings are verbatim from
    /// `docs/observations/2026-09-05-{en-US,ja-JP}-arrange-regions-census.json`.
    @Test("the canvas description Logic shows classifies as explicit track content",
          arguments: ["Tracks contents", "トラックコンテンツ"])
    func shownCanvasDescriptionIsExplicit(shown: String) {
        let normalized = shown
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { $0.isWhitespace }
            .joined(separator: " ")
        #expect(AXLocalePolicy.trackContentExplicit.labels.contains(normalized))
    }

    /// The generic fallback carries no Japanese form on purpose. The ja-JP
    /// census shows no AXGroup whose description is `コンテンツ`; the eight rows
    /// carrying that substring are menu titles, help sentences, and the
    /// explicit group itself. A form written here would be a translation of a
    /// string Logic does not show, which is what the ledger refuses.
    @Test("the generic content fallback has no Japanese form, because none was measured")
    func genericFallbackHasNoJapaneseForm() {
        #expect(!AXLocalePolicy.trackContentGeneric.labels.contains("コンテンツ"))
        #expect(!AXLocalePolicy.trackContentGeneric.labels.contains("トラックコンテンツ"))
    }

    // MARK: - Functional (drive the accessible classifiers, EN + KO)

    @Test("isProjectPickerWindow classifies the picker by title (EN + KO), not a real project",
          arguments: [
            ("Choose a Project", true),
            ("프로젝트 선택", true),
            ("New from Template", true),
            ("My Song - Tracks", false),
            ("Untitled 6 - Tracks", false),
          ])
    func projectPickerClassifier(title: String, expected: Bool) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(9100)
        let window = b.element(9101)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(window, kAXTitleAttribute as String, title)
        let isPicker = AXLogicProElements.isProjectPickerWindow(window, runtime: b.makeLogicRuntime(appElement: app))
        #expect(expected ? isPicker : !isPicker, "title=\(title)")
    }

    @Test("findPanControlInHeader locates the pan slider by Korean child description")
    func panLocatorKorean() {
        let b = FakeAXRuntimeBuilder()
        let header = b.element(9200)
        let pan = b.element(9201)
        b.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(pan, kAXDescriptionAttribute as String, "")
        let panIndicator = b.element(9202)
        b.setAttribute(panIndicator, kAXRoleAttribute as String, "AXValueIndicator")
        b.setAttribute(panIndicator, kAXDescriptionAttribute as String, "0 팬")
        b.setChildren(pan, [panIndicator])
        let vol = b.element(9203)
        b.setAttribute(vol, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(vol, kAXDescriptionAttribute as String, "볼륨")
        b.setChildren(header, [pan, vol])
        let found = AXLogicProElements.findPanControlInHeader(header, runtime: b.makeAXRuntime())
        #expect(found != nil && CFEqual(found!, pan))
    }

    @Test("isOccupiedPluginSlotElement recognizes the bypass+open label pair (EN + KO)",
          arguments: [("Bypass", "Open"), ("바이패스", "열기"), ("Bypass", "List"), ("바이패스", "목록")])
    func occupiedPluginSlotByLabel(bypassLabel: String, openLabel: String) {
        let b = FakeAXRuntimeBuilder()
        let slot = b.element(9300)
        b.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
        let bypass = b.element(9301)
        b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(bypass, kAXDescriptionAttribute as String, bypassLabel)
        let open = b.element(9302)
        b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(open, kAXDescriptionAttribute as String, openLabel)
        b.setChildren(slot, [bypass, open])
        #expect(AXLogicProElements.isOccupiedPluginSlotElement(slot, runtime: b.makeAXRuntime()))
    }

    @Test("pluginSlotDisplayName rejects automation-mode labels (EN + KO), accepts a real name",
          arguments: [
            ("읽기, 오토메이션이 활성화됨", nil as String?),
            ("Read", nil as String?),
            ("Volume Automation", nil as String?),
            ("채널 EQ 오토메이션", nil as String?),
            ("Channel EQ", "Channel EQ"),
            ("컴프레서", "컴프레서"),
          ])
    func pluginDisplayNameRejectsAutomation(description: String, expected: String?) {
        let b = FakeAXRuntimeBuilder()
        let slot = b.element(9400)
        b.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(slot, kAXDescriptionAttribute as String, description)
        let name = AXLogicProElements.pluginSlotDisplayName(slot, runtime: b.makeAXRuntime())
        #expect(name == expected, "desc=\(description)")
    }
}
