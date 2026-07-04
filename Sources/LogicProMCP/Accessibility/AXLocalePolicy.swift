import ApplicationServices
import Foundation

/// Central policy for unavoidable Logic UI text matching.
///
/// Callers should prefer AX structure, identifiers, roles, geometry, selected
/// state, and post-write readback. Use these label sets only where Logic exposes
/// no stable non-localized AX handle, and keep State A gated by independent
/// readback on write paths.
enum AXLocalePolicy {
    enum MatchMode {
        case exact
        case prefix
        case contains
        /// Whole-string equality WITHOUT whitespace trimming, case-insensitive.
        /// Preserves the raw `desc == label` / `desc.lowercased() == label`
        /// semantics used by structural control-bar / track-header locators that
        /// historically compared the AX description verbatim. Distinct from
        /// `.exact`, which trims surrounding whitespace.
        case exactStrict
    }

    struct LabelSet: Sendable, Equatable {
        let canonical: String
        let variants: [String]
        let rationale: String

        init(canonical: String, variants: [String], rationale: String) {
            self.canonical = canonical
            self.variants = variants
            self.rationale = rationale
        }

        var labels: [String] {
            var result: [String] = []
            for label in [canonical] + variants {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !result.contains(trimmed) {
                    result.append(trimmed)
                }
            }
            return result
        }

        func matches(_ text: String?, mode: MatchMode = .exact) -> Bool {
            guard let text else { return false }

            // `.exactStrict` compares the verbatim string (no trim) so it
            // preserves the historical `desc == label` semantics exactly. All
            // other modes trim surrounding whitespace, matching the existing
            // migrated policy behavior.
            if mode == .exactStrict {
                guard !text.isEmpty else { return false }
                return labels.contains { text.caseInsensitiveCompare($0) == .orderedSame }
            }

            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return false }

            return labels.contains { label in
                switch mode {
                case .exact:
                    candidate.caseInsensitiveCompare(label) == .orderedSame
                case .prefix:
                    // #60 — diacritic-SENSITIVE, matching `containsAny` (made
                    // sensitive in #122). Folding accents (e.g. "ínspector" →
                    // "inspector") WIDENS matching beyond the stored label and
                    // risks misclassifying accented-Latin AX text in non-EN/KO
                    // locales — the exact locale collision #60 guards against.
                    // The EN/KO LabelSets carry their real diacritics, so
                    // sensitive matching is both safer and correct.
                    candidate.range(
                        of: label,
                        options: [.anchored, .caseInsensitive]
                    ) != nil
                case .contains:
                    // #60 — diacritic-SENSITIVE (same rationale as `.prefix`).
                    candidate.range(
                        of: label,
                        options: [.caseInsensitive]
                    ) != nil
                case .exactStrict:
                    candidate.caseInsensitiveCompare(label) == .orderedSame
                }
            }
        }

        /// True if `haystack` contains ANY label as a substring.
        ///
        /// Faithfully mirrors the inline `combined.contains(token)` control flow
        /// it replaced: Swift's `String.contains` is case-sensitive,
        /// **diacritic-sensitive**, and canonical-equivalence aware. We use
        /// `.caseInsensitive` (inert on the already-lowercased aggregates the
        /// callers pass, and required for the one raw-string site) but
        /// deliberately do NOT add `.diacriticInsensitive` — folding accents
        /// (e.g. "ínspector" → "inspector") would WIDEN matching beyond the
        /// original and risk misclassifying accented-Latin AX text in non-EN/KO
        /// locales. Omitting `.literal` keeps Hangul NFC/NFD canonical matching,
        /// matching `String.contains`.
        func containsAny(in haystack: String) -> Bool {
            labels.contains { label in
                haystack.range(of: label, options: [.caseInsensitive]) != nil
            }
        }
    }

    struct MenuPath: Sendable, Equatable {
        let bar: LabelSet
        let item: LabelSet
        let itemMode: MatchMode

        init(bar: LabelSet, item: LabelSet, itemMode: MatchMode = .exact) {
            self.bar = bar
            self.item = item
            self.itemMode = itemMode
        }
    }

    static let viewMenuBar = LabelSet(
        canonical: "View",
        variants: ["보기"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic."
    )

    static let showMixerMenuItem = LabelSet(
        canonical: "Show Mixer",
        variants: ["믹서 보기"],
        rationale: "Used only as a best-effort mixer reveal before structural mixer readback."
    )

    static let windowMenuBar = LabelSet(
        canonical: "Window",
        variants: ["윈도우"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic."
    )

    static let hideAllPluginWindowsMenuItem = LabelSet(
        canonical: "Hide All Plug-in Windows",
        variants: ["모든 플러그인 윈도우 가리기"],
        rationale: "Best-effort cleanup so stale plugin windows do not steal later menu focus."
    )

    static let editMenuBar = LabelSet(
        canonical: "Edit",
        variants: ["편집"],
        rationale: "Undo is menu-only in the rollback path; post-undo inventory readback verifies outcome."
    )

    static let undoMenuItemPrefix = LabelSet(
        canonical: "Undo",
        variants: ["실행 취소"],
        rationale: "Menu item includes the operation name after the localized Undo prefix."
    )

    static let goToPositionDialogTitle = LabelSet(
        canonical: "Go to Position",
        variants: ["위치로 이동"],
        rationale: "Used only to dismiss a stale dialog before another verified operation."
    )

    static let cancelButton = LabelSet(
        canonical: "Cancel",
        variants: ["취소"],
        rationale: "Dialog dismissal fallback; no success state is inferred from this click."
    )

    static let saveConfirmationButton = LabelSet(
        canonical: "Save",
        variants: ["저장", "OK", "확인"],
        rationale: "Save As dialog commit button; file existence verifies the result."
    )

    static let pluginFormatLeafPriority: [LabelSet] = [
        LabelSet(canonical: "Stereo", variants: ["스테레오"], rationale: "Plugin format leaf after exact plugin selection."),
        LabelSet(canonical: "Mono", variants: ["모노"], rationale: "Plugin format leaf after exact plugin selection."),
        LabelSet(canonical: "Mono->Stereo", variants: ["모노->스테레오"], rationale: "Plugin format leaf after exact plugin selection."),
        LabelSet(canonical: "Dual Mono", variants: ["듀얼 모노"], rationale: "Plugin format leaf after exact plugin selection."),
    ]

    // MARK: - Read-only locator labels (Phase 2, issue #60)
    //
    // The label sets below back read-only AX locators / state extractors. None
    // of them gate a State-A success: they identify which control to read, or
    // classify a description string. Mutating callers still verify via
    // independent readback. They are centralized here so the EN/KO token pairs
    // live in one audited place; each preserves the EXACT match mode and token
    // order of its original call site.

    // --- Transport control identification (read-only, `.contains` semantics) ---

    static let transportPlayControl = LabelSet(
        canonical: "play",
        variants: ["재생"],
        rationale: "Identifies the Play transport control when reading TransportState; read-only."
    )

    static let transportRecordControl = LabelSet(
        canonical: "record",
        variants: ["녹음"],
        rationale: "Identifies the Record transport control; excluded by arm-tokens at the call site; read-only."
    )

    static let transportCycleControl = LabelSet(
        canonical: "cycle",
        variants: ["loop", "사이클"],
        rationale: "Identifies the Cycle/Loop transport control; read-only."
    )

    static let transportMetronomeControl = LabelSet(
        canonical: "metronome",
        variants: ["click", "메트로놈", "클릭"],
        rationale: "Identifies the Metronome/Click transport control; read-only."
    )

    /// Record-arm disambiguation tokens. Their PRESENCE on a Record control
    /// EXCLUDES it from being treated as the transport Record button.
    static let transportRecordArmExclusion = LabelSet(
        canonical: "arm",
        variants: ["활성화"],
        rationale: "Negative guard: distinguishes per-track record-arm from transport Record; read-only."
    )

    static let tempoFieldLabel = LabelSet(
        canonical: "tempo",
        variants: ["bpm", "템포"],
        rationale: "Identifies a tempo text field/slider description; read-only."
    )

    static let playheadPositionFieldLabel = LabelSet(
        canonical: "position",
        variants: ["재생헤드 위치"],
        rationale: "Identifies the playhead position text field description; read-only."
    )

    // --- Control-bar slider locators (read-only, verbatim `.exactStrict`) ---

    static let controlBarGroupLabel = LabelSet(
        canonical: "control bar",
        variants: ["컨트롤 막대"],
        rationale: "Identifies the control-bar AXGroup by description; read-only locator."
    )

    static let barSliderLabel = LabelSet(
        canonical: "bar",
        variants: ["마디"],
        rationale: "Identifies the bar slider in the control bar; verbatim description match; read-only."
    )

    static let beatSliderLabel = LabelSet(
        canonical: "beat",
        variants: ["비트"],
        rationale: "Identifies the beat slider in the control bar; verbatim description match; read-only."
    )

    /// Tempo slider description for `findTempoSlider` (verbatim `.exactStrict`).
    /// Includes `bpm` because that locator explicitly accepts `desc == "bpm"`.
    static let tempoSliderLabel = LabelSet(
        canonical: "tempo",
        variants: ["bpm", "템포"],
        rationale: "Identifies the tempo slider; verbatim (lowercased) description match; read-only."
    )

    /// Tempo slider description for the read-only `extractTransportState` slider
    /// loop, which historically matched ONLY `tempo`/`템포` via `.contains`
    /// (NOT `bpm`). Kept distinct from `tempoSliderLabel` to preserve behavior.
    static let tempoSliderContainsLabel = LabelSet(
        canonical: "tempo",
        variants: ["템포"],
        rationale: "Identifies the tempo slider in TransportState extraction; substring match without bpm; read-only."
    )

    /// #109: arrange Horizontal-Zoom slider (writable AXValue). EN canonical +
    /// KO variant; matched by description substring.
    static let horizontalZoomSlider = LabelSet(
        canonical: "Horizontal Zoom",
        variants: ["가로 확대/축소", "가로 확대"],
        rationale: "Locates the arrange horizontal-zoom AXSlider for verified set_zoom writes; description substring match."
    )

    // --- Track-header read-only locators ---

    static let trackMuteButton = LabelSet(
        canonical: "Mute",
        variants: ["음소거"],
        rationale: "Identifies the track Mute button by description substring; read-only state extraction."
    )

    static let trackSoloButton = LabelSet(
        canonical: "Solo",
        variants: ["솔로"],
        rationale: "Identifies the track Solo button by description substring; read-only state extraction."
    )

    static let trackRecordButton = LabelSet(
        canonical: "Record",
        variants: ["Rec", "녹음 활성화", "레코드 활성화"],
        rationale: "Identifies the track Record/arm button by description substring; read-only state extraction."
    )

    /// Per-track record-enable AXCheckBox description. Verbatim match preserves
    /// the original `desc == "녹음 활성화" || ...` locator semantics.
    static let trackRecordEnableCheckbox = LabelSet(
        canonical: "녹음 활성화",
        variants: ["Record Enable", "Record"],
        rationale: "Locates the per-track record-enable AXCheckBox; verbatim description match; read-only locator."
    )

    // --- Plugin Setting popup locator (read-only, `.contains`) ---

    static let settingPopupValue = LabelSet(
        canonical: "Preset",
        variants: ["프리셋", "Default", "기본"],
        rationale: "Identifies the plugin Setting AXPopUpButton by its value substring; read-only locator."
    )

    // MARK: - Read-only heuristic token bags (Phase 3, issue #60)
    //
    // These back read-only *classifiers* (which AX container is the marker
    // ruler / the transport-control bar). They are scanned with `.contains`
    // semantics over an already-lowercased aggregate string and never gate a
    // State-A success — purely "which region of the tree is this". Centralized
    // here as compatibility-hint token bags so the EN/KO pairs live in one
    // audited place; each preserves its call site's exact token list + order.

    /// Marker ruler keyword fallback (oldest locator path).
    static let markerContainerKeywords = LabelSet(
        canonical: "marker",
        variants: ["마커"],
        rationale: "Last-resort marker-ruler container classifier; read-only keyword scan."
    )

    /// Control-bar / transport container metadata tokens (id/title/desc scan).
    static let transportContainerMetadata = LabelSet(
        canonical: "transport",
        variants: ["control bar", "컨트롤 막대"],
        rationale: "Classifies the transport/control-bar container by metadata substring; read-only."
    )

    /// Transport control-button label tokens (≥2 distinct hits ⇒ transport bar).
    static let transportContainerControlKeywords = LabelSet(
        canonical: "play",
        variants: ["stop", "record", "cycle", "loop", "metronome", "rewind", "forward",
                   "재생", "녹음", "사이클", "메트로놈", "클릭"],
        rationale: "Counts distinct transport-control labels to classify the control bar; read-only."
    )

    /// Tempo/position slider description tokens inside the transport container.
    static let transportSliderHints = LabelSet(
        canonical: "tempo",
        variants: ["bpm", "position", "템포", "재생헤드 위치", "마디", "비트"],
        rationale: "Classifies tempo/position sliders inside the transport container; read-only."
    )

    // MARK: - Read-only classifier token bags (Phase 4, issue #60)
    //
    // Mixer / inspector / channel-strip / plugin-slot classifiers (surface #3)
    // and region / track-content / track-type classifiers (surface #5). All back
    // read-only predicates/locators — they decide "what kind of element/region is
    // this", never gate a State-A success. Each preserves its call site's EXACT
    // token list, source order, and match semantics (`.containsAny` for the
    // `text.contains(token)` || chains over an already-lowercased aggregate;
    // `.labels.contains(normalized)` for the normalized `==` predicates). Write
    // paths, AppleScript menu literals, and the region-bar regex are deliberately
    // NOT centralized here (separate, behavior-changing migrations).

    /// Inspector-context marker — prunes inspector ancestors from mixer scans.
    static let mixerInspectorContext = LabelSet(
        canonical: "inspector",
        variants: ["인스펙터"],
        rationale: "Marks an inspector ancestor so mixer-area detection skips it; read-only classifier."
    )

    /// Mixer container id/desc/title exact match (normalized lowercase equality).
    static let mixerNamedElement = LabelSet(
        canonical: "mixer",
        variants: ["믹서"],
        rationale: "Identifies the mixer container by exact normalized name; read-only classifier."
    )

    /// Slider type hints (mutually exclusive groups in `sliderText`).
    static let sliderSendHint = LabelSet(
        canonical: "send",
        variants: ["센드"],
        rationale: "Classifies a slider as a send control; read-only."
    )
    static let sliderZoomHint = LabelSet(
        canonical: "zoom",
        variants: ["확대"],
        rationale: "Classifies a slider as a zoom control; read-only."
    )
    static let sliderVolumeHint = LabelSet(
        canonical: "volume",
        variants: ["fader", "볼륨"],
        rationale: "Classifies a slider as a volume fader; read-only."
    )
    static let sliderPanHint = LabelSet(
        canonical: "pan",
        variants: ["panning", "패닝", "밸런스"],
        rationale: "Classifies a slider as a pan control; read-only."
    )

    /// Plugin-slot child control locators.
    static let pluginBypassControl = LabelSet(
        canonical: "bypass",
        variants: ["바이패스"],
        rationale: "Locates a plugin-slot bypass control by label; read-only locator (structural fallback exists)."
    )
    static let pluginOpenOrListControl = LabelSet(
        canonical: "open",
        variants: ["열기", "list", "목록"],
        rationale: "Locates a plugin-slot open/list control by label; read-only locator (structural fallback exists)."
    )

    /// #234: the "Compare" checkbox in a Logic plugin-EDITOR window. Combined
    /// with `pluginBypassControl` and the window's `kAXCloseButtonAttribute`, it
    /// forms the conjunctive chrome signature that classifies a plugin editor as
    /// NON-blocking (so unrelated ops proceed while it is open). English
    /// canonical only: the Korean/localized "Compare" label is UNVERIFIED
    /// (OQ-1 — English UI is the only live-confirmed locale), so `variants` stays
    /// empty and unverified locales conservatively remain BLOCKING (fail-closed)
    /// rather than risk excluding a real modal.
    static let pluginWindowCompareControl = LabelSet(
        canonical: "compare",
        variants: [],
        rationale: "Locates a plugin-editor window's Compare checkbox for the non-blocking chrome signature; English canonical only (OQ-1: Korean/localized unverified → unverified locales stay blocking, fail-closed). Read-only classifier."
    )

    /// #234: the channel-strip "Link" checkbox in a Logic plugin-EDITOR window.
    /// Present from the moment the editor first opens — UNLIKE the Compare
    /// checkbox, which only appears once the plugin has preset/edit state to
    /// compare (live 12.3 Gain evidence 2026-07-05, `axwhy234.out`). Combined with
    /// the bypass checkbox + close-button attribute it forms the alternative
    /// chrome branch (compare OR link) that recognizes a freshly-inserted editor.
    /// English canonical only; Korean/localized UNVERIFIED (OQ-1) → unverified
    /// locales conservatively stay BLOCKING (fail-closed).
    static let pluginWindowLinkControl = LabelSet(
        canonical: "link",
        variants: [],
        rationale: "Locates a plugin-editor window's channel-strip Link checkbox for the non-blocking chrome signature (present from first open, unlike Compare); English canonical only (OQ-1 fail-closed). Read-only classifier."
    )

    /// Automation-mode labels that must NOT be read as a plugin display name.
    static let pluginAutomationLabelExact = LabelSet(
        canonical: "읽기, 오토메이션이 활성화됨",
        variants: ["read"],
        rationale: "Rejects automation-mode slot labels (exact) when extracting a plugin display name; read-only filter."
    )
    static let pluginAutomationLabelSubstring = LabelSet(
        canonical: "automation",
        variants: ["오토메이션"],
        rationale: "Rejects automation-mode slot labels (substring) when extracting a plugin display name; read-only filter."
    )

    /// Empty audio-plugin insert-slot button classification.
    static let audioPluginSlotLabel = LabelSet(
        canonical: "audio plugin",
        variants: ["audio effect", "오디오 플러그인", "오디오 이펙트"],
        rationale: "Classifies an empty audio-plugin insert-slot button; read-only (structural fallback exists)."
    )
    static let sendOrIOControlLabel = LabelSet(
        canonical: "send",
        variants: ["센드", "input", "output", "입력", "출력"],
        rationale: "Excludes send/IO buttons from empty audio-plugin slot detection; read-only."
    )

    /// Negative-case table: button labels that are NOT empty insert slots.
    static let nonInsertButtonText = LabelSet(
        canonical: "send",
        variants: [
            "센드", "input", "입력", "output", "출력", "group", "그룹",
            "channel mode", "채널 모드", "eq", "setting", "설정",
            "gain reduction", "게인 축소", "mute", "음소거", "solo", "record", "녹음",
            "monitor", "모니터링", "volume", "볼륨", "fader", "페이더",
            "pan", "패닝", "밸런스",
        ],
        rationale: "Negative-case table excluding non-insert channel-strip buttons from empty-slot enumeration; read-only."
    )

    /// Track-header pan slider locator (header-level).
    static let headerPanHint = LabelSet(
        canonical: "pan",
        variants: ["팬", "밸런스"],
        rationale: "Locates the track-header pan slider by child description; read-only locator (structural fallback exists)."
    )

    /// Track-header rail description (normalized exact match).
    static let trackHeadersDescription = LabelSet(
        canonical: "track headers",
        variants: ["track header", "tracks header", "tracks headers", "트랙 헤더"],
        rationale: "Identifies the track-header rail by normalized description; read-only classifier (structural detection preferred)."
    )

    /// Choose-Project picker window title markers.
    static let projectPickerWindow = LabelSet(
        canonical: "프로젝트 선택",
        variants: ["choose a project", "choose project", "new from template"],
        rationale: "Distinguishes the Choose-Project picker window from a real project; read-only classifier."
    )

    /// Transport text-field description hints (tempo/position fields).
    static let transportTextFieldHint = LabelSet(
        canonical: "tempo",
        variants: ["bpm", "position", "템포", "재생헤드 위치"],
        rationale: "Classifies transport tempo/position text fields inside the control bar; read-only."
    )

    /// Region container "Track Content" group (normalized exact match).
    static let trackContentExplicit = LabelSet(
        canonical: "트랙 콘텐츠",
        variants: ["track content", "track contents", "tracks content", "tracks contents"],
        rationale: "Identifies the arrange Track-Content group by normalized description; read-only classifier."
    )
    static let trackContentGeneric = LabelSet(
        canonical: "콘텐츠",
        variants: ["content", "contents"],
        rationale: "Generic content-group fallback by normalized description; read-only classifier."
    )

    /// Region-kind classification by name+help substring.
    static let regionKindDrummer = LabelSet(
        canonical: "drummer",
        variants: ["session player", "드러머", "세션 플레이어"],
        rationale: "Classifies a region as drummer/session-player content; read-only."
    )
    static let regionKindMidi = LabelSet(
        canonical: "midi",
        variants: [],
        rationale: "Classifies a region as MIDI content; read-only."
    )
    static let regionKindAudio = LabelSet(
        canonical: "audio",
        variants: ["오디오"],
        rationale: "Classifies a region as audio content; read-only."
    )

    /// Region detection by AXHelp keyword.
    static let regionHelpKeyword = LabelSet(
        canonical: "region",
        variants: ["리전"],
        rationale: "Detects an arrange region by its AXHelp string; read-only classifier."
    )

    static let showMixerMenuPath = MenuPath(bar: viewMenuBar, item: showMixerMenuItem)
    static let hidePluginWindowsMenuPath = MenuPath(bar: windowMenuBar, item: hideAllPluginWindowsMenuItem)
    static let editUndoMenuPath = MenuPath(bar: editMenuBar, item: undoMenuItemPrefix, itemMode: .prefix)

    static func elementMatches(
        _ element: AXUIElement,
        _ labels: LabelSet,
        mode: MatchMode = .exact,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        labels.matches(AXHelpers.getTitle(element, runtime: runtime), mode: mode)
            || labels.matches(AXHelpers.getDescription(element, runtime: runtime), mode: mode)
    }

    static func findMenuBarItem(
        in menuBar: AXUIElement,
        matching labels: LabelSet,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.getChildren(menuBar, runtime: runtime).first {
            elementMatches($0, labels, runtime: runtime)
        }
    }

    static func findMenuItem(
        under menuBarItem: AXUIElement,
        matching labels: LabelSet,
        mode: MatchMode = .exact,
        maxDepth: Int = 5,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.findAllDescendants(
            of: menuBarItem,
            role: kAXMenuItemRole as String,
            maxDepth: maxDepth,
            runtime: runtime
        ).first {
            elementMatches($0, labels, mode: mode, runtime: runtime)
        }
    }

    static func findDescendant(
        of element: AXUIElement,
        role: String,
        matching labels: LabelSet,
        mode: MatchMode = .exact,
        maxDepth: Int = 5,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.findAllDescendants(of: element, role: role, maxDepth: maxDepth, runtime: runtime).first {
            elementMatches($0, labels, mode: mode, runtime: runtime)
        }
    }
}
