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

    static let showStepInputKeyboardMenuItem = LabelSet(
        canonical: "Show Step Input Keyboard",
        variants: ["스텝 입력 키보드 보기"],
        rationale: "Native Window-menu toggle used with independent window-state readback."
    )

    static let stepInputKeyboardWindowTitle = LabelSet(
        canonical: "Step Input Keyboard",
        variants: ["스텝 입력 키보드"],
        rationale: "Verifies the Step Input Keyboard window opened or closed after the menu action."
    )

    /// Variants are READ FROM THE LIVE MENU BAR, never translated by hand. Measured on a Korean
    /// Logic 12.3: the File menu is `파일` and its first entry is `신규` (U+C2E0 U+ADDC) — not the
    /// `새로 만들기` a translator would reach for, which is the whole reason these are measured.
    /// Event List column headers. Every variant is READ FROM A LIVE LOGIC, never translated.
    /// Measured 2026-08-11 on Logic 12.3 in Korean; the English forms stay the canonical column
    /// identity, so a snapshot taken in one language is comparable with one taken in another.
    ///
    /// The collector compared these positionally against English literals, so on a Korean Logic it
    /// threw `headerMismatch` and the note readback could not run at all — the `English and Korean
    /// locale coverage` proof `MIDIProviderGate` requires of this provider.
    static let eventListColumnL = LabelSet(canonical: "L", variants: [],
        rationale: "Event List lock column; unlabelled in every locale measured.")
    static let eventListColumnM = LabelSet(canonical: "M", variants: [],
        rationale: "Event List mute column; unlabelled in every locale measured.")
    static let eventListColumnPosition = LabelSet(canonical: "Position", variants: ["위치"],
        rationale: "Event List position column; identity is the canonical English form.")
    static let eventListColumnStatus = LabelSet(canonical: "Status", variants: ["상태"],
        rationale: "Event List status column; identity is the canonical English form.")
    static let eventListColumnChannel = LabelSet(canonical: "Ch", variants: ["채널"],
        rationale: "Event List channel column; identity is the canonical English form.")
    static let eventListColumnNumber = LabelSet(canonical: "Num", variants: ["번호"],
        rationale: "Event List number column; identity is the canonical English form.")
    static let eventListColumnValue = LabelSet(canonical: "Val", variants: ["값"],
        rationale: "Event List value column; identity is the canonical English form.")
    static let eventListColumnLengthInfo = LabelSet(canonical: "Length/Info", variants: ["길이/정보"],
        rationale: "Event List length column; identity is the canonical English form.")

    /// The region-level header, which is how the collector tells "you are looking at the wrong level"
    /// apart from "Logic changed its columns". Measured in Korean as
    /// `["L","M","위치","이름","트랙","길이"]`.
    static let eventListColumnName = LabelSet(canonical: "Name", variants: ["이름"],
        rationale: "Region-level name column; distinguishes the region list from the event list.")
    static let eventListColumnTrack = LabelSet(canonical: "Trk", variants: ["트랙"],
        rationale: "Region-level track column; distinguishes the region list from the event list.")
    static let eventListColumnLength = LabelSet(canonical: "Length", variants: ["길이"],
        rationale: "Region-level length column; distinguishes the region list from the event list.")

    /// The Event pane's "position and length as Time" toggle. Matched by title on the pane's own View
    /// menu; a Time-mode reading is refused because the collector's tick arithmetic assumes bars and
    /// beats. Korean variant to be measured before it is claimed — this entry has not been read on a
    /// non-English Logic yet, and an invented translation is worse than an English-only match that
    /// fails closed.
    static let eventPositionAsTimeMenuItem = LabelSet(
        canonical: "Event Position and Length as Time",
        variants: [],
        rationale: "Decides whether Event List positions are bar/beat or timecode; read-only."
    )

    static let fileMenuBar = LabelSet(
        canonical: "File",
        variants: ["파일", "ファイル"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic."
    )

    static let newProjectMenuItem = LabelSet(
        canonical: "New",
        variants: ["신규", "新規"],
        rationale: "Reveals the New Project chooser, or creates the project directly where Logic skips it."
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

    /// What the Edit-menu Undo entry says when the thing on top of the stack is a plug-in insert.
    ///
    /// The rollback path matched only the "Undo" prefix, so it pressed whatever was on top. Measured
    /// on Logic 12.3 the entry for our own insert reads "Undo Insert Plug-in in Channel Strip", and
    /// the same menu offers unrelated entries such as "Undo selected Channel Strips" — pressing one
    /// of those undoes the user's work instead of ours.
    static let undoPluginInsertMenuItem = LabelSet(
        canonical: "Insert Plug-in in Channel Strip",
        variants: ["채널 스트립에 플러그인 삽입"],
        rationale: "Confirms the Undo entry describes OUR insert before a rollback presses it."
    )

    static let goToPositionDialogTitle = LabelSet(
        canonical: "Go To Position",
        variants: ["위치로 이동"],
        rationale: "Used only to dismiss a stale dialog before another verified operation."
    )

    static let cancelButton = LabelSet(
        canonical: "Cancel",
        variants: ["취소", "キャンセル"],
        rationale: "Dialog dismissal fallback; no success state is inferred from this click. JA live-confirmed (Logic 12.3: `キャンセル`)."
    )

    /// #346/#350: the mandatory New Track sheet's only exit ("Create"). The modal
    /// reconciler clicks it to un-wedge Logic, then verifies via track-count
    /// readback — the click itself gates no State-A success. KO live-confirmed
    /// (Logic 12.3: `생성`); JA live-confirmed (Logic 12.3: `作成`).
    static let createButton = LabelSet(
        canonical: "Create",
        variants: ["생성", "作成"],
        rationale: "Mandatory New Track sheet's only exit; reconciler-clicked, then verified by track-count readback. KO live-confirmed (Logic 12.3); JA live-confirmed (Logic 12.3: `作成`)."
    )

    /// #346/#350: `AXDescription` that identifies the mandatory New Track sheet.
    /// An independent signal the reconciler uses to classify the sheet; on
    /// Japanese Logic 12.3 the Cancel button is enabled. Read-only classifier;
    /// KO live-confirmed (Logic 12.3: `새로운 트랙`); JA live-confirmed (Logic 12.3:
    /// `新規トラック`).
    static let newTrackSheetDescription = LabelSet(
        canonical: "New Track",
        variants: ["새로운 트랙", "新規トラック"],
        rationale: "Identifies the mandatory New Track sheet by AXDescription, independently of Cancel state; read-only classifier. KO live-confirmed (Logic 12.3); JA live-confirmed (Logic 12.3: `新規トラック`, Cancel enabled)."
    )

    /// #346/#350: primary destructive button on the "delete channel strips that
    /// are assigned to tracks!" confirm sheet. KO variant is UNVERIFIED (no live
    /// capture), so `variants` stays empty; KO detection degrades to the
    /// structural `Delete `-prefix check (fail-closed — a wrong-title guess or
    /// keyboard fallback is never fabricated).
    static let deleteTracksPrimaryButton = LabelSet(
        canonical: "Delete Tracks and Content",
        variants: [],
        rationale: "Primary destructive button on the delete-channel-strips confirm sheet; reconciler presses only the classifier-bound AX element. KO UNVERIFIED → variants empty (fail-closed structural matching; no keyboard fallback)."
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
        variants: ["재생", "再生"],
        rationale: "Identifies the Play transport control when reading TransportState; read-only."
    )

    static let transportRecordControl = LabelSet(
        canonical: "record",
        variants: ["녹음", "録音"],
        rationale: "Identifies the Record transport control; excluded by arm-tokens at the call site; read-only."
    )

    static let transportCycleControl = LabelSet(
        canonical: "cycle",
        variants: ["loop", "사이클", "サイクル"],
        rationale: "Identifies the Cycle/Loop transport control; read-only."
    )

    /// Japanese Logic labels this control with ONE compound string, `メトロノームクリック`,
    /// not with either half. Matching here is `.exactStrict`, so `メトロノーム` and `クリック`
    /// alone find nothing on a Japanese install — measured live 2026-08-10 by switching the
    /// application to Japanese and enumerating the control bar's 90 checkboxes.
    ///
    /// The two halves are kept: Logic uses bare `クリック` on other surfaces, and a label that
    /// costs nothing to carry should not be removed on the strength of one build.
    static let transportMetronomeControl = LabelSet(
        canonical: "metronome",
        variants: ["click", "메트로놈", "클릭", "メトロノームクリック", "メトロノーム", "クリック"],
        rationale: "Identifies the Metronome/Click transport control; read-only."
    )

    static let transportAutopunchControl = LabelSet(
        canonical: "Autopunch",
        variants: ["Auto Punch", "Auto-Punch"],
        rationale: "Locates Logic's Control Bar Autopunch checkbox for AXPress; State A is still gated by readback."
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
        variants: ["컨트롤 막대", "コントロールバー"],
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

    /// The suffix Logic appends to the arrange window's title. Measured live on 2026-08-11: an
    /// English Logic shows `Untitled 55 - Tracks` and a Korean one `Untitled 55 - 트랙`
    /// (U+D2B8 U+B799). `project.new` uses this suffix as its witness that a project was created, so
    /// an English-only literal made the operation report failure for a project it had just created —
    /// the #516 regression, still live for anyone not running Logic in English.
    static let arrangeWindowTitleSuffix = LabelSet(
        canonical: "Tracks",
        variants: ["트랙", "トラック"],
        rationale: "Witnesses that an arrange window exists after project.new; read-only classification."
    )

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

    // --- Track-header automation-mode read (WS3 AC2, value-only honesty fix) ---
    //
    // `logic://tracks` previously fabricated `automationMode = .off`. These label
    // sets classify the mode carried on the track-header automation control's
    // description/value. `automationModeContext` GATES the read so unrelated
    // "read"/"write" AX text elsewhere in the header cannot be misread as an
    // automation mode. Read-only classifiers — none gate a State-A success; on
    // no match the caller RETAINS the pre-fix `.off` default. English canonical
    // is the only live-confirmed locale (OQ-1 per #234); Korean variants are
    // best-effort and, when absent, degrade safely to the unchanged `.off`.
    static let automationModeContext = LabelSet(
        canonical: "automation",
        variants: ["오토메이션"],
        rationale: "Gates the track-header automation-mode read to the automation control; read-only classifier."
    )
    static let automationModeWrite = LabelSet(
        canonical: "write",
        variants: ["쓰기"],
        rationale: "Classifies the track-header automation mode as Write; read-only classifier."
    )
    static let automationModeTrim = LabelSet(
        canonical: "trim",
        variants: ["트림"],
        rationale: "Classifies the track-header automation mode as Trim; read-only classifier."
    )
    static let automationModeTouch = LabelSet(
        canonical: "touch",
        variants: ["터치"],
        rationale: "Classifies the track-header automation mode as Touch; read-only classifier."
    )
    static let automationModeLatch = LabelSet(
        canonical: "latch",
        variants: ["래치"],
        rationale: "Classifies the track-header automation mode as Latch; read-only classifier."
    )
    static let automationModeRead = LabelSet(
        canonical: "read",
        variants: ["읽기"],
        rationale: "Classifies the track-header automation mode as Read; read-only classifier."
    )
    static let automationModeOff = LabelSet(
        canonical: "off",
        variants: ["끔"],
        rationale: "Classifies an explicit track-header automation Off token; read-only classifier."
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

    /// Title-suffix patterns for the Logic Marker List window across the
    /// localisations Apple ships. Relocated from AXLogicProElements (round-1 #7)
    /// so the localized token tables live in one audited place. The window title
    /// is `"<project name> - <localized 'Marker List'>"`, so the caller matches
    /// by `hasSuffix` (a diacritic-sensitive, case-sensitive scalar comparison —
    /// NOT a LabelSet match mode). Extending this array is the safe path when a
    /// new locale surfaces.
    static let markerListWindowSuffixes: [String] = [
        "- 마커 목록",          // Korean
        "- Marker List",         // English
        "- マーカーリスト",      // Japanese
        "- マーカー一覧",        // Japanese (alt — older Logic)
        "- Liste des marqueurs", // French
        "- Markerliste",         // German
        "- Lista de marcadores", // Spanish
        "- Elenco marker",       // Italian
        "- 标记列表",            // Chinese (Simplified)
        "- 標記列表",            // Chinese (Traditional)
        "- Список меток",        // Russian
        "- Lista de marcadores", // Portuguese (PT/BR same form)
        "- Lijst met markers"    // Dutch
    ]

    /// Localized placeholder AXDescription that Logic's Marker List `AXCell`s
    /// carry by default (the localized word for "cell"). Relocated from
    /// AXLogicProElements (round-1 #7). The caller skips these via `Set.contains`
    /// (a diacritic-sensitive, case-sensitive exact match — NOT a LabelSet match
    /// mode) when extracting meaningful cell content.
    static let markerCellPlaceholders: Set<String> = [
        "셀",       // Korean
        "Cell",     // English
        "セル",     // Japanese
        "Cellule",  // French
        "Zelle",    // German
        "Celda",    // Spanish (also "Célula" in some locales)
        "Cella",    // Italian
        "单元格",   // Chinese (Simplified)
        "儲存格",   // Chinese (Traditional)
        "Ячейка",   // Russian
        "Célula",   // Portuguese
        "Cel"       // Dutch
    ]

    /// Live Library panel/browser identifier (LibraryAccessor). Preserves the
    /// original `desc == "라이브러리" || desc.lowercased() == "library"` locator
    /// (round-1 #7): a whole-string, case-insensitive, DIACRITIC-SENSITIVE match
    /// — use with `.exactStrict`. Read-only locator; the browser is otherwise
    /// selected structurally, and a wrong match only widens/narrows a fallback.
    static let libraryPanelLabel = LabelSet(
        canonical: "library",
        variants: ["라이브러리"],
        rationale: "Identifies the Library panel/browser by whole-string description; read-only locator (structural fallback exists)."
    )

    /// Control-bar / transport container metadata tokens (id/title/desc scan).
    static let transportContainerMetadata = LabelSet(
        canonical: "transport",
        variants: ["control bar", "컨트롤 막대", "コントロールバー"],
        rationale: "Classifies the transport/control-bar container by metadata substring; read-only."
    )

    /// Transport control-button label tokens (≥2 distinct hits ⇒ transport bar).
    static let transportContainerControlKeywords = LabelSet(
        canonical: "play",
        variants: ["stop", "record", "cycle", "loop", "metronome", "rewind", "forward",
                   "재생", "녹음", "사이클", "메트로놈", "클릭",
                   "再生", "録音", "サイクル", "メトロノーム", "クリック"],
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

    /// #405: the "Smart Controls" toggle in a Drummer track's docked Smart Controls
    /// pane. Combined with an AXDialog subrole and an empty window title it forms
    /// the `isSmartControlsWindow` signature that classifies that pane as
    /// NON-blocking (it is tagged AXDialog but, unlike a plugin editor, carries no
    /// close-button attribute, so the plugin-editor signature never matched it).
    /// English canonical only: the localized "Smart Controls" label is UNVERIFIED
    /// (OQ-1), so `variants` stays empty and non-EN panes conservatively remain
    /// BLOCKING (fail-closed) rather than risk excluding a real modal.
    static let pluginWindowSmartControlsControl = LabelSet(
        canonical: "smart controls",
        variants: [],
        rationale: "Locates the Smart Controls toggle in a Drummer track's docked Smart Controls pane for the non-blocking classifier; English canonical only (OQ-1: localized label unverified → non-EN panes stay blocking, fail-closed). Read-only classifier."
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

    /// Track-type classification tokens (read-only; `inferTrackType`). Centralized
    /// per round-1 #6 — the 오디오/악기 tokens were previously inline. Scanned with
    /// `.containsAny` over the already-lowercased header aggregate, which is
    /// diacritic-sensitive and case-insensitive — behavior-identical to the inline
    /// lowercased `String.contains` they replaced. The CALLER preserves the exact
    /// precedence order (GM Device wins over audio per #131). None gate a
    /// State-A success.
    static let trackTypeGMDevice = LabelSet(
        canonical: "gm device",
        variants: [],
        rationale: "Classifies a GM Device external-MIDI strip; MUST win over .audio (#131 silent-bounce guard); read-only."
    )
    static let trackTypeAudio = LabelSet(
        canonical: "audio",
        variants: ["오디오"],
        rationale: "Classifies an audio track by header aggregate; read-only classifier."
    )
    static let trackTypeInstrument = LabelSet(
        canonical: "instrument",
        variants: ["software", "악기"],
        rationale: "Classifies a software-instrument track; read-only classifier."
    )
    static let trackTypeDrummer = LabelSet(
        canonical: "drummer",
        variants: [],
        rationale: "Classifies a drummer track; read-only classifier."
    )
    static let trackTypeExternalMIDI = LabelSet(
        canonical: "external",
        variants: ["midi"],
        rationale: "Classifies an external-MIDI track; read-only classifier."
    )
    static let trackTypeAux = LabelSet(
        canonical: "aux",
        variants: [],
        rationale: "Classifies an aux track; read-only classifier."
    )
    static let trackTypeBus = LabelSet(
        canonical: "bus",
        variants: [],
        rationale: "Classifies a bus track; read-only classifier."
    )
    static let trackTypeMaster = LabelSet(
        canonical: "master",
        variants: ["stereo out"],
        rationale: "Classifies the master / stereo-out track; read-only classifier."
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
    static let showStepInputKeyboardMenuPath = MenuPath(
        bar: windowMenuBar,
        item: showStepInputKeyboardMenuItem
    )
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
