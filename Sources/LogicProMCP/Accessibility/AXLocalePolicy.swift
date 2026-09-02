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

    /// #369: File > Export. Both forms were read from Logic's File menu; no other locale has been
    /// measured for this submenu, so callers must refuse rather than translate or guess one.
    static let exportMenuItem = LabelSet(
        canonical: "Export",
        variants: ["내보내기"],
        rationale: "File submenu title measured in English and Korean; a locale without one of these labels is refused as an unmeasured stem-export menu label."
    )

    /// #369: File > Export > All Tracks as Audio Files… — the only measured leaf that reaches the
    /// one-file-per-track export panel. Exact labels deliberately distinguish all three audio-file
    /// entries that share the rest of their wording. English identifies the target with `All Tracks`,
    /// rather than the selection-rewritten singular `1 Track as Audio File…` or a `Selected…` range
    /// entry. Korean identifies it with `모든 트랙을`, rather than `1개의 트랙을` or `선택 범위를`.
    /// The discriminator is therefore locale-specific: the English word `selected` is not assumed to
    /// exist in Korean. Only these English and Korean forms are measured; other locales must refuse
    /// as an unmeasured all-tracks-audio-file label instead of falling back to keyword matching.
    static let allTracksAsAudioFilesMenuItem = LabelSet(
        canonical: "All Tracks as Audio Files…",
        variants: ["모든 트랙을 오디오 파일로…"],
        rationale: "Measured all-tracks audio-file export leaf: EN uses `All Tracks` against singular/Selected entries; KO uses `모든 트랙을` against `1개의 트랙을` and `선택 범위를`."
    )

    /// #369: controls inside the per-track stem-export panel. The panel's own
    /// window title is the OS Open-panel string, so it is not a usable signal.
    static let oneFilePerTrackPopupValue = LabelSet(
        canonical: "One File per Track",
        variants: ["트랙당 하나의 파일"],
        rationale: "Measured from the live stem-export panel on 2026-09-01; the panel window title is the OS Open-panel string and is therefore not a usable signal."
    )

    static let stemExportCommitButton = LabelSet(
        canonical: "Export",
        variants: ["내보내기"],
        rationale: "Measured from the live stem-export panel on 2026-09-01; the panel window title is the OS Open-panel string and is therefore not a usable signal."
    )

    static let stemExportDismissButton = LabelSet(
        canonical: "Cancel",
        variants: ["취소"],
        rationale: "Measured from the live stem-export panel on 2026-09-01; the panel window title is the OS Open-panel string and is therefore not a usable signal."
    )

    /// #369: The transient progress window title is rendered with an ordinary
    /// space in some locales and a NO-BREAK SPACE in Korean. Keep the measured
    /// product label in locale policy rather than scattering a literal through
    /// the export driver.
    static let stemExportProgressWindowTitle = LabelSet(
        canonical: "Logic Pro",
        variants: [],
        rationale: "Measured on the live Korean progress dialog on 2026-09-02 as `Logic\\u{00A0}Pro`; whitespace is normalized only for this product-title rendering."
    )

    static func progressWindowTitleMatches(_ title: String) -> Bool {
        let normalized = String(title.map { $0.isWhitespace ? " " : $0 })
        return stemExportProgressWindowTitle.matches(normalized)
    }

    static let editMenuBar = LabelSet(
        canonical: "Edit",
        variants: ["편집", "編集"],
        rationale: "Undo is menu-only in the rollback path; post-undo inventory readback verifies outcome."
    )

    /// #519: the Navigate menu bar item. All three labels are MEASURED, none translated.
    ///
    /// `移動` was read off a live Logic 12.3 running `AppleLanguages=ja` on 2026-08-17. It is worth
    /// naming explicitly because a plausible translation gives `ナビゲート`, and Logic does not use that
    /// — so a reader who "corrects" this to the obvious word breaks Japanese silently. (An earlier
    /// revision of this comment said no Japanese form had been measured, which was stale and pointed
    /// a future editor straight at deleting the measured label.)
    static let navigateMenuBar = LabelSet(
        canonical: "Navigate",
        variants: ["탐색", "移動"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic."
    )

    /// #519: the Track menu bar item.
    ///
    /// All three labels were already in the tree, as three hard-coded strings inside
    /// `clickTrackMenu` — `"트랙"`, `"Track"` and `"トラック"`, the last carrying its own comment that it
    /// was measured on Logic 12.3 with `AppleLanguages=ja` and is a third spelling rather than a
    /// variant. Moving them here does not add a measurement; it puts them where the next measured
    /// language can join them instead of becoming a fourth element in a literal array.
    static let trackMenuBar = LabelSet(
        canonical: "Track",
        variants: ["트랙", "トラック"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic."
    )

    /// #519: File > Save As…
    ///
    /// The English label was MEASURED on 2026-08-19 by enumerating the File menu on a live Logic
    /// 12.3 — the trailing character is a real ellipsis, not three dots, and matching on "Save As"
    /// alone would also hit "Save A Copy As…" and "Save as Template…", both of which sit two rows
    /// away in the same menu.
    ///
    /// The Korean variant is carried over from the literal it replaces in
    /// `AccessibilityChannel+Project.swift`, where it shipped as one half of a Korean-then-English
    /// pair. I did not re-measure it on a Korean Logic, so its provenance is "already trusted in
    /// shipped code", not "measured by me" — recorded here so nobody reads it as a fresh observation.
    ///
    /// **There is NO Japanese variant, and `save_as` therefore does not resolve on a Japanese Logic.**
    /// The File menu BAR has a measured `ファイル`, and an early draft of this change let that fact
    /// stand in for the item — "Japanese works without a third literal" — which it does not: the bar
    /// resolving is worthless if the item does not. The item's Japanese label has never been read off
    /// a live Japanese Logic, and this repository does not translate labels into a LabelSet. So the
    /// gap is recorded rather than papered over, and `Issue519SaveAsMenuLocaleTests` asserts the
    /// absence so it cannot quietly become an assumption.
    ///
    /// This is not a regression: the two hard-coded literals it replaces had exactly the same gap.
    static let saveAsMenuItem = LabelSet(
        canonical: "Save As…",
        variants: ["다른 이름으로 저장…"],
        rationale: "File menu entry that opens the Save panel; the panel is the only path to save_as."
    )

    /// #519: File > Bounce.
    static let bounceMenuItem = LabelSet(
        canonical: "Bounce",
        variants: ["바운스"],
        rationale: "File menu entry that opens the Bounce dialog; menu-only in the AppleScript bounce path."
    )

    /// #519: the Bounce submenu's "Project or Section…" leaf. Both the curly-ellipsis (`…`) and
    /// literal three-dot (`...`) renderings have been observed across Logic builds, in both
    /// locales, so all four spellings are kept rather than assuming one glyph.
    static let projectOrSectionMenuItem = LabelSet(
        canonical: "Project or Section…",
        variants: ["프로젝트 또는 섹션…", "Project or Section...", "프로젝트 또는 섹션..."],
        rationale: "Bounce dialog's menu-driven entry point; multiple ellipsis renderings observed across Logic builds."
    )

    /// #519: File > Import.
    static let importMenuItem = LabelSet(
        canonical: "Import",
        variants: ["가져오기", "読み込む"],
        rationale: "File menu entry that opens the Import submenu used by midi.import_file."
    )

    /// #519: File > Import > MIDI File….
    static let midiFileMenuItem = LabelSet(
        canonical: "MIDI File…",
        variants: ["MIDI 파일…", "MIDIファイル…"],
        rationale: "Import submenu leaf that opens the MIDI file chooser for midi.import_file."
    )

    /// #519: Edit > Move.
    static let moveMenuItem = LabelSet(
        canonical: "Move",
        variants: ["이동"],
        rationale: "Edit menu entry that opens the Move submenu used to reposition a selected region."
    )

    /// #519: Edit > Move > To Playhead.
    static let toPlayheadMenuItem = LabelSet(
        canonical: "To Playhead",
        variants: ["재생헤드로"],
        rationale: "Move submenu leaf that repositions the selected region to the playhead."
    )

    /// #519: Navigate > Set Locators….
    static let setLocatorsMenuItem = LabelSet(
        canonical: "Set Locators…",
        variants: ["로케이터 설정…"],
        rationale: "Navigate menu entry that opens the cycle-range locator dialog."
    )

    /// #519: Navigate > Go To. Korean Logic renders this the same `이동` string as Edit > Move
    /// (`moveMenuItem`) — the two LabelSets deliberately share that surface form under different
    /// English canonicals; each is scoped to its own menu bar by the caller's resolved parent
    /// specifier, so the shared Korean text never crosses into the wrong menu.
    static let goToMenuItem = LabelSet(
        canonical: "Go To",
        variants: ["이동", "移動"],
        rationale: "Navigate menu entry that opens the Go To submenu used by goto_position."
    )

    /// #519: Navigate > Go To > Position….
    static let goToPositionMenuItem = LabelSet(
        canonical: "Position…",
        variants: ["위치…", "位置…"],
        rationale: "Go To submenu leaf that opens the Go To Position dialog."
    )

    /// #519: Navigate > Open Marker List.
    static let openMarkerListMenuItem = LabelSet(
        canonical: "Open Marker List",
        variants: ["마커 목록 열기", "マーカーリストを開く"],
        rationale: "Navigate menu entry that opens the Marker List window."
    )

    /// #519: Navigate > Create Marker.
    static let createMarkerMenuItem = LabelSet(
        canonical: "Create Marker",
        variants: ["마커 생성", "マーカーを作成"],
        rationale: "Navigate menu entry that creates a marker at the playhead."
    )

    /// The Marker List toolbar's own Edit menu button, not the application menu bar.
    static let markerListEditMenuButton = LabelSet(
        canonical: "Edit",
        variants: ["編集", "편집"],
        rationale: "Live-confirmed on Logic 12.3: the Marker List toolbar AXMenuButton exposes the exact AXDescription `編集` in Japanese and `편집` in Korean; the bottom AXButton with the same label is deliberately rejected unless its actions advertise AXShowMenu."
    )

    /// The Marker List's own "Number of Items" static text — Logic's independent rendering of
    /// the marker count, used as a second witness alongside the table's row projections. Matched
    /// against both AXDescription and AXHelp, mirroring the Event List reader's
    /// `readStaticText(help:)` precedent for the same node.
    ///
    /// All three forms are read off a live Logic 12.3, never translated: the app was switched with
    /// `defaults write com.apple.logic10 AppleLanguages`, restarted, and the node's AXDescription
    /// read directly. Both localized forms answer the SAME string on AXDescription and AXHelp, and
    /// the Korean one carries a space (`항목 수`) while the Japanese one does not (`項目数`) — which
    /// is why they are pinned as measured strings and not derived from one another.
    static let markerListNumberOfItemsLabel = LabelSet(
        canonical: "Number of Items",
        variants: ["항목 수", "項目数"],
        rationale: "Live-measured on Logic 12.3 on 2026-08-17: AXDescription and AXHelp both read `항목 수` in Korean and `項目数` in Japanese, alongside the English `Number of Items`. Until that date this LabelSet deliberately carried no variants because none had been measured; the values it renders were measured in the same pass (`2개의 마커`, `0個のマーカー`) and drove the count parser's separator rule."
    )

    /// The destructive Marker List Edit-menu command. This must always be whole-string matched.
    static let markerListDeleteMenuItem = LabelSet(
        canonical: "Delete",
        variants: ["削除", "삭제"],
        rationale: "Live-confirmed on Logic 12.3: Marker List Delete is `削除` in Japanese and `삭제` in Korean. It is used only with exactStrict because the Edit menu also has Delete-Undo-History entries; prefix or containment matching can reach a different destructive command."
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
        variants: ["위치로 이동", "位置の移動"],
        rationale: "Used only to dismiss a stale dialog before another verified operation. This covers the reviewed EN/KO/JA dialog titles; broader locale/menu policy remains tracked separately."
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

    /// #346/#350/#545: primary destructive button on the track-delete confirm sheets.
    /// English forms are live-measured; non-English forms are NOT, so they are absent
    /// rather than guessed and those locales degrade to fail-closed structural matching
    /// (a wrong-title guess or keyboard fallback is never fabricated).
    static let deleteTracksPrimaryButton = LabelSet(
        canonical: "Delete Tracks and Content",
        variants: ["Delete", "삭제", "削除"],
        rationale: """
        Primary destructive button on a track-delete confirm sheet; the reconciler presses only the \
        classifier-bound AX element. Logic uses more than one of these sheets and they do NOT share a \
        button label: "Delete Tracks and Content" on the channel-strip sheet, and a bare "Delete" on \
        "Delete Track and Regions?" (track carries regions) and "Delete Track and Cells?" (Live Loops \
        cells) — both measured live on 12.3. The bare label is why #545 happened: the structural \
        fallback tested `hasPrefix("Delete ")`, with a trailing space, which "Delete" does not satisfy, \
        so those sheets classified as unknown and were left on screen. Accepting the bare label is safe \
        because `decide` only confirms a delete when `isDeleteContext` is true and preflight never acts \
        on `.deleteConfirm` at all.

        NOT MEASURED: the KO and JA forms of this bare button. A revision of this set carried 삭제 and         削除, which were translated by hand rather than read from the live sheet — the one thing the         header of this file forbids, and forbids because a hand translation was already wrong here once         (New is 신규, not the 새로 만들기 a translator reaches for). Outside English the bare-label         sheets therefore still classify as unknown, which is the pre-#545 behaviour: fail-closed, dialog         left on screen. That is a real remaining gap, tracked with the other locale work in #519, and it         is stated rather than papered over with a guess that would silently press an unidentified         destructive button.
        """
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

    static let playheadPositionGroupLabel = LabelSet(
        canonical: "playhead position",
        variants: ["재생헤드 위치", "再生ヘッド位置"],
        rationale: "Identifies Logic 12.3's Playhead Position AXGroup before resolving its bar/beat component sliders."
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

    /// Labels that carry a transport keyword without being a transport control.
    ///
    /// `transportContainerControlKeywords` matches with `contains`, which is required: Korean and
    /// Japanese labels have no word boundaries, so `재생헤드` can only be reached by substring. The
    /// cost is that short generic words match unrelated controls, and two of them put the ARRANGE
    /// AREA into `looksLikeTransportContainer` — measured 2026-08-21, Logic 12.3:
    ///
    ///     "play" ⊂ "Catch Playhead"                 "loop" ⊂ "Show/Hide Live Loops Grid"
    ///
    /// Those two alone gave the track area the two distinct keywords the rule needs, so
    /// `getTransportBar`'s scan had four survivors where it should have had two.
    ///
    /// Measured in BOTH shipped locales by running the same window under `AppleLanguages -array en`
    /// and `-array ko`, because the Korean forms are not translations of the English ones:
    ///
    ///     Catch Playhead              재생헤드 캐치
    ///     Playhead Position           재생헤드 위치
    ///     Playhead thumb              재생헤드 썸네일
    ///     Loop Browser                루프 브라우저
    ///     Show/Hide Live Loops Grid   Live Loop 그리드 보기/가리기   ← keeps the ENGLISH "Loop"
    ///     Session Player              Session Player                ← untranslated, keeps "play"
    ///
    /// The last two are why this is a measured table and not a translation: a guard written only in
    /// Korean would miss labels that stay English inside a Korean UI, and a guard written only in
    /// English would miss `재생헤드 캐치`. Both halves were read off a live window.
    ///
    /// ja-JP is NOT here. Nobody has read these labels off a Japanese Logic, and the ship scope is
    /// Desktop × {en-US, ko-KR}. Inventing them is the defect #519 exists to remove.
    static let transportKeywordFalseFriends = LabelSet(
        canonical: "catch playhead",
        variants: ["playhead position", "playhead thumb", "loop browser", "session player",
                   "show/hide live loops grid", "live loops grid",
                   "재생헤드 캐치", "재생헤드 위치", "재생헤드 썸네일", "루프 브라우저",
                   "live loop 그리드 보기/가리기"],
        rationale: "Negative guard: labels carrying a transport keyword that are not transport "
            + "controls. Measured en-US and ko-KR on Logic 12.3; read-only."
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

    /// Controls/editor switching is deliberately keyed from AXDescription:
    /// live Compressor evidence on 2026-09-02 showed the `AXMenuButton`
    /// description is the localized View label, while AXTitle is the most
    /// recently selected view *or zoom* menu item and is not a view readback.
    /// English `View` and Korean `보기` are the only measured descriptions;
    /// another locale must refuse rather than treating an arbitrary menu
    /// button as the view switcher.
    static let pluginWindowViewSwitcher = LabelSet(
        canonical: "View",
        variants: ["보기"],
        rationale: "Measured live on 2026-09-02 in Compressor: the Controls/editor AXMenuButton identifies itself by AXDescription (View/보기); AXTitle is not a view readback."
    )

    /// The measured Controls item in the scoped plugin-window View menu.
    /// `Controls` and `컨트롤` were measured live on 2026-09-02; this is not a
    /// translation table for unmeasured locales and is never used as a title
    /// readback.
    static let pluginWindowControlsViewMenuItem = LabelSet(
        canonical: "Controls",
        variants: ["컨트롤"],
        rationale: "Measured live on 2026-09-02 in Compressor's scoped View menu; use to select Controls only."
    )

    /// The measured native-editor item in the scoped plugin-window View menu.
    /// `Editor` and `편집기` are not inferred translations and are never used
    /// as a title readback.
    static let pluginWindowEditorViewMenuItem = LabelSet(
        canonical: "Editor",
        variants: ["편집기"],
        rationale: "Measured live on 2026-09-02 in Compressor's scoped View menu; paired evidence for Controls/컨트롤."
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
    /// No longer consulted in production as of 2026-08-24. `headerPanSliderCandidates` was its only
    /// caller and now uses `sliderPanHint` via `sliderText`, which reads `AXHelp` and is what
    /// identifies the same control on a mixer strip — this set searched children's `AXDescription`
    /// and measured zero survivors on every header.
    ///
    /// Left in place rather than deleted. Its `팬` variant is not in `sliderPanHint`, so removing it
    /// would drop a label from the repository on the strength of one measurement, in one locale, on
    /// one Logic version — a narrowing dressed up as a cleanup. Whether `팬` belongs in
    /// `sliderPanHint`, and whether this set should then go, is a separate question with its own
    /// evidence: no tree measured so far contains `팬` at all, and `팬` does not occur inside
    /// `패닝` (different syllables), so it has never been the variant doing the work.
    static let headerPanHint = LabelSet(
        canonical: "pan",
        variants: ["팬", "밸런스"],
        rationale: "Retired locator for the track-header pan slider; superseded by sliderPanHint."
    )

    /// Track-header rail description (normalized exact match).
    static let trackHeadersDescription = LabelSet(
        canonical: "track headers",
        variants: ["track header", "tracks header", "tracks headers", "트랙 헤더"],
        rationale: "Identifies the track-header rail by normalized description; read-only classifier (structural detection preferred)."
    )

    /// The Event tab of the List Editors pane, by `AXDescription`.
    ///
    /// `EventListReadbackCollector` compared this description against the literal `"Event"`, so on
    /// a Logic running in any other language the tab could not be found and the collector threw
    /// `eventTabNotFound` — a readback that cannot start rather than one that reads wrong.
    /// Measured 2026-08-29 on a Korean Logic: the four list tabs describe themselves
    /// `이벤트`, `마커`, `템포`, `조표 및 박자표`.
    static let eventListTab = LabelSet(
        canonical: "event",
        variants: ["이벤트", "イベント"],
        rationale: "Identifies the Event tab of the List Editors pane; the collector presses it."
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
    /// Identifies a channel strip's OUTPUT slot by its AXHelp string (#291).
    ///
    /// Measured on Logic Pro 12.3, English: the slot is an `AXButton` whose help reads "Output slot.
    /// Click and hold to choose the channel strip output…" and whose DESCRIPTION carries the current
    /// destination ("Stereo Output"). The send slot beside it is described only as "send button" and,
    /// when empty, exposes no `AXValue`, `AXValueDescription` or `AXTitle` at all — so an output can
    /// be read and a send destination cannot.
    ///
    /// Only the English rendering is measured. A Logic in another language yields no match, which
    /// makes the reader report nothing rather than guess — and the caller sees an absent output
    /// rather than a wrong one. The variants list grows when a locale is actually observed, not when
    /// one is translated.
    static let outputSlotHelpKeyword = LabelSet(
        canonical: "output slot",
        variants: [],
        rationale: "Detects a channel strip's output slot by its AXHelp string; read-only classifier."
    )

    /// Identifies a channel strip's INPUT slot by its AXHelp string (#291).
    ///
    /// Measured on Logic Pro 12.3, English, on an audio track: the slot is an `AXButton` whose help
    /// reads "Input slot. Choose the channel strip input source…" and whose DESCRIPTION carries the
    /// current source ("Input 1"). A software-instrument strip has no such button at all, so an
    /// absent input there is the truth rather than a gap.
    ///
    /// The keyword is the full phrase "input slot" and not "input", because the same strip carries an
    /// `AXButton` whose help begins "Input Monitoring button. Hear incoming signal…" — a prefix match
    /// on the word alone would publish the monitoring toggle as an input source.
    ///
    /// Only the English rendering is measured; the empty variants list is the same fail-closed choice
    /// as `outputSlotHelpKeyword`.
    static let inputSlotHelpKeyword = LabelSet(
        canonical: "input slot",
        variants: [],
        rationale: "Detects a channel strip's input slot by its AXHelp string; read-only classifier."
    )

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

    /// What a lookup found AND how many candidates it had to choose between.
    ///
    /// `findDescendant` above returns the first match in traversal order and says nothing about the
    /// rest. When it is right, nothing records that it was right for a reason rather than by luck —
    /// and that silence is the defect, not the choosing. Measured on one arrange window,
    /// `AXDescription` "Control Bar" matches two elements, "Library" four, "Event" three; a lookup
    /// for any of them returns something plausible either way.
    ///
    /// `candidates` is the whole point. `1` is a fact a later reader can weigh. Absence is not.
    /// The counting contract lives in `AXHelpers`, the layer both census forms sit on. It was
    /// declared here first, when only the label-matching form existed; giving the identifier form
    /// its own copy would have produced two structs that mean the same thing and drift apart.
    typealias Census = AXHelpers.Census

    /// Every match, with the count, so a caller can refuse ambiguity instead of inheriting
    /// traversal order. Deliberately additive: `findDescendant` keeps its behaviour, and adoption is
    /// counted rather than forced, because flipping every call site at once would turn a census into
    /// a wall of red and the next move after that is somebody deleting the check.
    static func censusDescendant(
        of element: AXUIElement,
        role: String,
        matching labels: LabelSet,
        mode: MatchMode = .exact,
        maxDepth: Int = 5,
        runtime: AXHelpers.Runtime
    ) -> Census {
        let hits = AXHelpers.findAllDescendants(
            of: element, role: role, maxDepth: maxDepth, runtime: runtime
        ).filter { elementMatches($0, labels, mode: mode, runtime: runtime) }
        return Census(element: hits.count == 1 ? hits[0] : nil, candidates: hits.count, matches: hits)
    }

    /// Status-preserving counterpart to `censusDescendant` for a localized
    /// label lookup. It is deliberately additive: ordinary read-only callers
    /// keep the historical best-effort census, while a caller using a menu item
    /// as write authority can refuse an unreadable title or description rather
    /// than reporting that item as missing.
    static func censusDescendantResult(
        of element: AXUIElement,
        role: String,
        matching labels: LabelSet,
        mode: MatchMode = .exact,
        maxDepth: Int = 5,
        runtime: AXHelpers.Runtime
    ) -> Result<Census, AXHelpers.AXStatusError> {
        let roleCensus: AXHelpers.Census
        switch AXHelpers.censusDescendantResult(
            of: element,
            role: role,
            maxDepth: maxDepth,
            runtime: runtime
        ) {
        case let .success(observed):
            roleCensus = observed
        case let .failure(error):
            return .failure(error)
        }

        var hits: [AXUIElement] = []
        for candidate in roleCensus.matches {
            switch elementMatchesResult(candidate, labels, mode: mode, runtime: runtime) {
            case .success(true):
                hits.append(candidate)
            case .success(false):
                continue
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(Census(
            element: hits.count == 1 ? hits[0] : nil,
            candidates: hits.count,
            matches: hits
        ))
    }

    private static func elementMatchesResult(
        _ element: AXUIElement,
        _ labels: LabelSet,
        mode: MatchMode,
        runtime: AXHelpers.Runtime
    ) -> Result<Bool, AXHelpers.AXStatusError> {
        let title: String?
        switch stringAttributeResult(element, kAXTitleAttribute as String, runtime: runtime) {
        case let .success(observed):
            title = observed
        case let .failure(error):
            return .failure(error)
        }
        if labels.matches(title, mode: mode) {
            return .success(true)
        }

        let description: String?
        switch stringAttributeResult(element, kAXDescriptionAttribute as String, runtime: runtime) {
        case let .success(observed):
            description = observed
        case let .failure(error):
            return .failure(error)
        }
        return .success(labels.matches(description, mode: mode))
    }

    private static func stringAttributeResult(
        _ element: AXUIElement,
        _ attribute: String,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, AXHelpers.AXStatusError> {
        let read: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            element,
            attribute,
            runtime: runtime
        )
        switch read {
        case let .success(value):
            return .success(value)
        case let .failure(error) where error.isDefinitiveAbsence:
            return .success(nil)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Every `LabelSet` declared above, for callers that need to ask "does the product recognise
    /// this string at all" rather than "does it match this particular set".
    ///
    /// Hand-maintained, and `AXLocalePolicyCoverageTests` fails when it diverges from the
    /// declarations — the same treatment the selector/operation map gets, for the same reason.
    ///
    /// An omission here OVER-redacts an AX snapshot: a label the product knows would be recorded as
    /// a shape instead of verbatim. That is the safe direction and it is why this list being a copy
    /// is tolerable at all; the unsafe direction is not reachable from a missing entry.
    static let allLabelSets: [LabelSet] = [
        viewMenuBar,
        pluginWindowViewSwitcher,
        pluginWindowControlsViewMenuItem,
        pluginWindowEditorViewMenuItem,
        showMixerMenuItem,
        windowMenuBar,
        hideAllPluginWindowsMenuItem,
        showStepInputKeyboardMenuItem,
        stepInputKeyboardWindowTitle,
        eventListColumnL,
        eventListColumnM,
        eventListColumnPosition,
        eventListColumnStatus,
        eventListColumnChannel,
        eventListColumnNumber,
        eventListColumnValue,
        eventListColumnLengthInfo,
        eventListColumnName,
        eventListColumnTrack,
        eventListColumnLength,
        eventPositionAsTimeMenuItem,
        fileMenuBar,
        newProjectMenuItem,
        exportMenuItem,
        allTracksAsAudioFilesMenuItem,
        oneFilePerTrackPopupValue,
        stemExportCommitButton,
        stemExportDismissButton,
        stemExportProgressWindowTitle,
        editMenuBar,
        navigateMenuBar,
        trackMenuBar,
        saveAsMenuItem,
        bounceMenuItem,
        projectOrSectionMenuItem,
        importMenuItem,
        midiFileMenuItem,
        moveMenuItem,
        toPlayheadMenuItem,
        setLocatorsMenuItem,
        goToMenuItem,
        goToPositionMenuItem,
        openMarkerListMenuItem,
        createMarkerMenuItem,
        markerListEditMenuButton,
        markerListNumberOfItemsLabel,
        markerListDeleteMenuItem,
        undoMenuItemPrefix,
        undoPluginInsertMenuItem,
        goToPositionDialogTitle,
        cancelButton,
        createButton,
        newTrackSheetDescription,
        deleteTracksPrimaryButton,
        saveConfirmationButton,
        transportPlayControl,
        transportRecordControl,
        transportCycleControl,
        transportMetronomeControl,
        transportAutopunchControl,
        transportRecordArmExclusion,
        tempoFieldLabel,
        playheadPositionFieldLabel,
        playheadPositionGroupLabel,
        controlBarGroupLabel,
        barSliderLabel,
        beatSliderLabel,
        tempoSliderLabel,
        tempoSliderContainsLabel,
        horizontalZoomSlider,
        arrangeWindowTitleSuffix,
        trackMuteButton,
        trackSoloButton,
        trackRecordButton,
        trackRecordEnableCheckbox,
        automationModeContext,
        automationModeWrite,
        automationModeTrim,
        automationModeTouch,
        automationModeLatch,
        automationModeRead,
        automationModeOff,
        settingPopupValue,
        markerContainerKeywords,
        libraryPanelLabel,
        transportContainerMetadata,
        transportContainerControlKeywords,
        transportKeywordFalseFriends,
        transportSliderHints,
        mixerInspectorContext,
        mixerNamedElement,
        sliderSendHint,
        sliderZoomHint,
        sliderVolumeHint,
        sliderPanHint,
        pluginBypassControl,
        pluginOpenOrListControl,
        pluginWindowSmartControlsControl,
        pluginAutomationLabelExact,
        pluginAutomationLabelSubstring,
        audioPluginSlotLabel,
        sendOrIOControlLabel,
        nonInsertButtonText,
        trackTypeGMDevice,
        trackTypeAudio,
        trackTypeInstrument,
        trackTypeDrummer,
        trackTypeExternalMIDI,
        trackTypeAux,
        trackTypeBus,
        trackTypeMaster,
        headerPanHint,
        trackHeadersDescription,
        eventListTab,
        projectPickerWindow,
        transportTextFieldHint,
        trackContentExplicit,
        trackContentGeneric,
        regionKindDrummer,
        regionKindMidi,
        regionKindAudio,
        outputSlotHelpKeyword,
        inputSlotHelpKeyword,
        regionHelpKeyword,
    ]
}
