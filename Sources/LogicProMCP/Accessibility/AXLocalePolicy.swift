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

        /// The row in Apple's own data these strings are the values of, when there is one.
        ///
        /// A `logic-canon://` reference naming a `(unit, key)`. A `.strings` row is ONE control's
        /// text in every locale at once, so a label that names its row does not need a variant per
        /// language read off a machine running Logic in that language -- which is what ten locales
        /// used to cost, and why six of the ten Logic ships had never been read at all (#892).
        ///
        /// It is not a second copy of the strings. `variants` stays the list this product matches
        /// with, including the tolerance Apple's data deliberately does not contain -- `Auto Punch`
        /// beside `Autopunch`. What the reference adds is a CHECK: for each of the ten locales,
        /// `Scripts/check-labelsets-are-derived.py` requires one of these strings to be the value
        /// Apple ships at that row, by digest, offline, on a machine with no Logic.
        ///
        /// `nil` means no row was named, not that none exists. Measured over all 159 LabelSets:
        /// 112 have a row that one can be chosen from mechanically, 30 are ambiguous between rows
        /// that disagree, and 17 have none -- fourteen of those being lowercase fragments matched
        /// by containment, which were never whole labels and so are not values of anything.
        let derivedFrom: String?

        init(canonical: String, variants: [String], rationale: String,
             derivedFrom: String? = nil) {
            self.canonical = canonical
            self.variants = variants
            self.rationale = rationale
            self.derivedFrom = derivedFrom
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
        /// Normalized-exact membership: trim, collapse internal whitespace runs,
        /// and compare WITHOUT case.
        ///
        /// The three classifier call sites used to normalize inline and then ask
        /// raw `labels.contains(_:)`, which is case-SENSITIVE while the
        /// normalization lowercases. A variant Logic renders with capitals could
        /// therefore never match. Measured live 2026-09-13: German region
        /// readback failed with `Track Content group not found` while the
        /// landmark list printed inside that very error contained
        /// `Spuren enthält` — the label was in the policy and unreachable.
        /// Every other matcher on this type is case-insensitive; this one is now
        /// too, and it owns the normalization so no call site restates it.
        func containsNormalized(_ text: String?) -> Bool {
            guard let text else { return false }
            let normalized = LabelSet.normalize(text)
            guard !normalized.isEmpty else { return false }
            return labels.contains { LabelSet.normalize($0) == normalized }
        }

        static func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split { $0.isWhitespace }
                .joined(separator: " ")
        }

        func containsAny(in haystack: String) -> Bool {
            labels.contains { label in
                haystack.range(of: label, options: [.caseInsensitive]) != nil
            }
        }

        /// True when `haystack` BEGINS with one of the labels.
        ///
        /// Separate from `containsAny` because for some elements the phrase appears inside a
        /// NEIGHBOUR's help as well. Measured in the ko-KR census: the right inspector strip's help
        /// is `오른쪽 인스펙터 채널 스트립. … 왼쪽 인스펙터 채널 스트립의 출력 …`, which contains the
        /// LEFT strip's phrase in a later sentence. A locator built on `containsAny` therefore
        /// accepts the wrong element, and the set that needs this is the one whose name already
        /// said `Prefix`.
        func hasPrefixAny(_ haystack: String) -> Bool {
            let text = haystack.trimmingCharacters(in: .whitespacesAndNewlines)
            return labels.contains { label in
                text.range(of: label, options: [.caseInsensitive, .anchored]) != nil
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
        variants: ["보기", "表示", "Ansicht", "Visualización", "Présentation", "Vista", "Visualizar", "显示", "顯示方式"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires. Extended on 2026-09-16 from the row Apple keys this menu title under -- Apple suffixes menu titles `#mti` and all 48 such keys carry all ten locales -- so every language Logic ships is covered. The reference and its value are cited in docs/observations/2026-09-16-seven-languages-reported-unknown.json. The variants read off running Logics before this change are each one of that row's own values -- nothing measured was dropped, and nothing was typed.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/View%23mti#value"
    )

    /// The third item this Logic build spells without a Show/Hide verb: the
    /// View menu's entry is `Mixer`, not `Show Mixer`, in all three censuses of
    /// 2026-09-05. Found by a unit-test fixture failing on its NEIGHBOUR — the
    /// near-miss check did not report it, because `Show Mixer` against `Mixer`
    /// scores 0.72 and the cutoff is 0.86, which is the limit that check prints
    /// beside its own output.
    /// The View menu's mixer entry CARRIES ITS VERB and changes with the pane's state. Measured
    /// 2026-09-06 by opening the menu before reading it:
    ///
    ///     mixer closed -> `Show Mixer`      mixer open -> `Hide Mixer`
    ///
    /// It never reads bare `Mixer`. A run of #778 changed the canonical to `Mixer` on the strength
    /// of the en-US census, which records `AXMenuItem[Mixer]` under the View menu — and that value
    /// is STALE: the census walks the menu bar without opening the menus, so a state-dependent item
    /// is recorded with whatever name was cached when the menu was last built. Reading the same
    /// item without opening it reproduces `Mixer` today while the opened menu says `Show Mixer`.
    ///
    /// The consequence was not cosmetic: the reveal looks the item up by exact match, so with the
    /// mixer closed it found nothing — `mixer_reveal_menu_item_found: false` — and
    /// `plugins.get_inventory` returned State B `mixer_not_visible` on a Logic whose View menu had
    /// the entry all along.
    ///
    /// Both English forms are listed because the reveal must FIND the item in either state; which
    /// one is present is what tells it whether a click is needed. The Korean form is the one this
    /// label shipped with before that change. Japanese is deliberately absent rather than guessed:
    /// the only ja string available is the same stale census reading.
    static let showMixerMenuItem = LabelSet(
        canonical: "Show Mixer",
        variants: ["Hide Mixer", "믹서 보기"],
        rationale: "Used only as a best-effort mixer reveal before structural mixer readback."
    )

    static let windowMenuBar = LabelSet(
        canonical: "Window",
        variants: ["윈도우", "ウインドウ", "Fenster", "Ventana", "Fenêtre", "Finestra", "Janela", "窗口", "視窗"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires. Extended on 2026-09-16 from the row Apple keys this menu title under -- Apple suffixes menu titles `#mti` and all 48 such keys carry all ten locales -- so every language Logic ships is covered. The reference and its value are cited in docs/observations/2026-09-16-seven-languages-reported-unknown.json. The variants read off running Logics before this change are each one of that row's own values -- nothing measured was dropped, and nothing was typed.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Window%23mti#value"
    )

    /// This Logic build shows `All Plug-in Windows`, with no verb. `Hide All
    /// Plug-in Windows` stood here and matches nothing; the item is a leaf with
    /// no submenu, so the old spelling could not resolve at a deeper level
    /// either. All three forms below are verbatim from the censuses of
    /// 2026-09-05 — the Korean one carried `…가리기`, "…hide", and was wrong for
    /// the same reason the English one was.
    static let hideAllPluginWindowsMenuItem = LabelSet(
        canonical: "All Plug-in Windows",
        variants: ["모든 플러그인 윈도우", "すべてのプラグインウインドウ", "Alle Plug-in-Fenster", "Todas las ventanas de módulos", "Toutes les fenêtres de module", "tutte le finestre dei plugin", "Todas as Janelas de Plug‑ins", "所有插件窗口", "所有外掛模組視窗"],
        rationale: "Best-effort cleanup so stale plugin windows do not steal later menu focus. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/All%20Plug-in%20Windows%23acc#value"
    )

    /// Same change, and this one was load-bearing: `edit.toggle_step_input`
    /// resolves this item, and with `Show Step Input Keyboard` it answered
    /// State C `element_not_found` and opened nothing — on an ENGLISH Logic,
    /// twice, with the window list unchanged across both calls. Logic shows
    /// `Step Input Keyboard`.
    /// Logic prefixes this item with a VERB that its own label set does not carry. Measured live on
    /// 2026-09-12, Logic 12.3 (6674), en-US UI: the Window menu offers `Show Step Input Keyboard`,
    /// and — unlike most show/hide pairs — it reads `Show …` in BOTH states. Clicking it with the
    /// window already open still closes it, so the verb is not a state readback either.
    ///
    /// An `.exact` match on the bare name therefore matched nothing, and `edit.toggle_step_input`
    /// answered `Window > Step Input Keyboard was not found` on a menu that plainly carries it. The
    /// path below matches on CONTAINMENT of the measured core string, so the verb may be present or
    /// absent and may be localized independently of the name — which is what the Korean and
    /// Japanese forms here already assume, since neither was measured WITH a verb attached.
    static let showStepInputKeyboardMenuItem = LabelSet(
        canonical: "Step Input Keyboard",
        variants: ["스텝 입력 키보드", "ステップインプットキーボード", "Step-Input-Keyboard", "Teclado de introducción por pasos", "Clavier d’entrée pas à pas", "tastiera di inserimento step", "Teclado de Entrada de Passos", "逐个输入键盘", "循步輸入鍵盤"],
        rationale: "Native Window-menu toggle, matched by containment because Logic prefixes a verb this set does not carry. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Step%20Input%20Keyboard%23acc#value"
    )

    /// Japanese measured live 2026-09-06, from Logic's own window list during a toggle:
    /// `lpm-locale-campaign - ステップインプットキーボード`. No navigation-free census can carry
    /// this string — the window does not exist until the operation opens it — which is why the
    /// gap survived three censuses and two rounds of menu-label work.
    ///
    /// Its absence is the SECOND half of why `edit.toggle_step_input` was dead in Japanese. With
    /// the menu labels fixed the AX channel found the item and pressed it, the window opened, and
    /// then this readback could not see it: twenty polls, State C, and the chain fell through to
    /// the key-command destination, which toggles the window but cannot read anything back. The
    /// operation reported State B `readback_unavailable` about a window that was plainly open.
    static let stepInputKeyboardWindowTitle = LabelSet(
        canonical: "Step Input Keyboard",
        variants: ["스텝 입력 키보드", "ステップインプットキーボード", "Step-Input-Keyboard", "Teclado de introducción por pasos", "Clavier d’entrée pas à pas", "tastiera di inserimento step", "Teclado de Entrada de Passos", "逐个输入键盘", "循步輸入鍵盤"],
        rationale: "Verifies the Step Input Keyboard window opened or closed after the menu action."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Step%20Input%20Keyboard%23acc#value"
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
    static let eventListColumnL = LabelSet(canonical: "L", variants: ["G", "S", "E", "锁定", "左"],
        rationale: "Event List lock column; unlabelled in every locale measured."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/L#value")
    static let eventListColumnM = LabelSet(canonical: "M", variants: ["静音"],
        rationale: "Event List mute column."
            + " The Event List builds its columns in code -- no nib in the bundle names `EventListView` -- and `-[EventListView columnTitle:forMenu:]` looks each header up in Logic.framework's own Localizable.strings under this key. Read from the shipped binary on 2026-09-20 (Logic 12.3 build 6674) rather than chosen because a value matched: docs/observations/2026-09-20-the-event-list-names-its-columns-in-code.json. Checked offline per locale by Scripts/check-labelsets-are-derived.py."
            + " Nine locales spell it `M`; Simplified Chinese spells it 静音 -- mute -- which is"
            + " also what separates this row from MAMixer's `M`, whose zh_CN value stays `M`.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/M#value")
    static let eventListColumnPosition = LabelSet(canonical: "Position", variants: ["위치", "ポジション", "Posición", "Posizione", "Posição", "位置"],
        rationale: "Event List position column."
            + " The Event List builds its columns in code -- no nib in the bundle names `EventListView` -- and `-[EventListView columnTitle:forMenu:]` looks each header up in Logic.framework's own Localizable.strings under this key. Read from the shipped binary on 2026-09-20 (Logic 12.3 build 6674) rather than chosen because a value matched: docs/observations/2026-09-20-the-event-list-names-its-columns-in-code.json. Checked offline per locale by Scripts/check-labelsets-are-derived.py."
            + " Japanese reads ポジション here. Seven rows in the bundle carry `Position` in English"
            + " and three of them read 位置 in Japanese; which one this column uses could not be"
            + " decided by value alone, which is why the binary was read.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Position#value")
    static let eventListColumnStatus = LabelSet(canonical: "Status", variants: ["상태", "状況", "Estado", "État", "Stato", "状态", "狀態"],
        rationale: "Event List status column; identity is the canonical English form."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FContentRelocation.strings/en/QR6-Rb-bj7.headerCell.title#value")
    static let eventListColumnChannel = LabelSet(canonical: "Ch", variants: ["채널", "Kan.", "Can.", "Ca.", "Canale", "Canal", "通道", "聲道"],
        rationale: "Event List channel column; identity is the canonical English form."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Ch#value")
    static let eventListColumnNumber = LabelSet(canonical: "Num", variants: ["번호", "番号", "Núm.", "Nombre", "Núm", "编号", "數量"],
        rationale: "Event List number column; identity is the canonical English form."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Num#value")
    static let eventListColumnValue = LabelSet(canonical: "Val", variants: ["값", "値", "Val.", "Valeur", "值"],
        rationale: "Event List value column; identity is the canonical English form."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Val#value")
    static let eventListColumnLengthInfo = LabelSet(canonical: "Length/Info", variants: ["길이/정보", "長さ/情報", "Länge/Info", "Longitud/info", "Durée/Infos", "Lunghezza/informazioni", "Duração/Informações", "长度/简介", "長度/資訊"],
        rationale: "Event List length column; identity is the canonical English form."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Length%2FInfo#value")

    /// The region-level header, which is how the collector tells "you are looking at the wrong level"
    /// apart from "Logic changed its columns". Measured in Korean as
    /// `["L","M","위치","이름","트랙","길이"]`.
    static let eventListColumnName = LabelSet(canonical: "Name", variants: ["이름", "名前", "Nombre", "Nom", "Nome", "名称", "名稱"],
        rationale: "Region-level name column; distinguishes the region list from the event list."
            + " The Event List builds its columns in code -- no nib in the bundle names `EventListView` -- and `-[EventListView columnTitle:forMenu:]` looks each header up in Logic.framework's own Localizable.strings under this key. Read from the shipped binary on 2026-09-20 (Logic 12.3 build 6674) rather than chosen because a value matched: docs/observations/2026-09-20-the-event-list-names-its-columns-in-code.json. Checked offline per locale by Scripts/check-labelsets-are-derived.py."
            + " Eighteen rows in the bundle carry `Name` in English, seventeen of them with the"
            + " same ten-locale spelling, so the values were never in doubt and the row was.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Name#value")
    static let eventListColumnTrack = LabelSet(canonical: "Trk", variants: ["트랙", "Pista", "Piste", "Trc", "Pis", "轨道", "音軌"],
        rationale: "Region-level track column; distinguishes the region list from the event list."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Trk#value")
    static let eventListColumnLength = LabelSet(canonical: "Length", variants: ["길이", "長さ", "Länge", "duración", "Durée", "Lunghezza", "Duração", "长度", "長度"],
        rationale: "Region-level length column; distinguishes the region list from the event list."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#und` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Length%23und#value")

    /// The Event pane's "position and length as Time" toggle. Matched by title on the pane's own View
    /// menu; a Time-mode reading is refused because the collector's tick arithmetic assumes bars and
    /// beats. Korean variant to be measured before it is claimed — this entry has not been read on a
    /// non-English Logic yet, and an invented translation is worse than an English-only match that
    /// fails closed.
    static let eventPositionAsTimeMenuItem = LabelSet(
        canonical: "Event Position and Length as Time",
        variants: ["이벤트 위치 및 길이를 시간으로", "イベントの位置と長さを時間で表示", "Event-Position und Länge als Zeit einblenden", "Posición y longitud del evento como tiempo", "Position et durée de l’évènement sous forme de temps", "Posizione e durata evento come tempo", "Posição e Duração do Evento como Tempo", "用时间表示的事件位置和长度", "以時間顯示事件位置和長度"],
        rationale: "Decides whether Event List positions are bar/beat or timecode; read-only."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Event%20Position%20and%20Length%20as%20Time#value"
    )

    static let fileMenuBar = LabelSet(
        canonical: "File",
        variants: ["파일", "ファイル", "Ablage", "Archivo", "Fichier", "Arquivo", "文件", "檔案"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires. Extended on 2026-09-16 from the row Apple keys this menu title under -- Apple suffixes menu titles `#mti` and all 48 such keys carry all ten locales -- so every language Logic ships is covered. The reference and its value are cited in docs/observations/2026-09-16-seven-languages-reported-unknown.json. The variants read off running Logics before this change are each one of that row's own values -- nothing measured was dropped, and nothing was typed.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/File%23mti#value"
    )

    /// #885 -- the three strings `project.new`'s chooser branch matched as bare English literals, so
    /// that branch could never match on a non-English Logic. Korean read live 2026-09-15 on Logic
    /// 12.3 (6674) via `파일 > 템플릿으로부터 신규…` with no document open; record
    /// `2026-09-15-the-korean-project-chooser-names-itself`. ja-JP and de-DE are NOT measured and
    /// carry no variant, so this reader gains nothing on those hosts until someone reads them --
    /// which is the point: a translated guess would look right and match nothing.
    static let projectChooserWindowTitle = LabelSet(
        canonical: "Choose a Project",
        variants: ["프로젝트 선택", "プロジェクトを選択", "Wähle ein Projekt aus", "Seleccionar un proyecto", "Choisir un projet", "Scegli un progetto", "Escolha um projeto", "选取项目", "選擇計畫案"],
        rationale: "Identifies Logic's New Project chooser by its AXWindow title; read-only classification. Korean read live 2026-09-15 off the window `파일 > 템플릿으로부터 신규…` opened with no document, whose title was `프로젝트 선택` exactly (AXStandardWindow, not an AXDialog). ja-JP and de-DE were unmeasured as of that date (#885) -- superseded below."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Choose%20a%20Project#value"
    )

    static let projectChooserCommitButton = LabelSet(
        canonical: "Choose",
        variants: ["선택", "選択", "Auswählen", "Seleccionar", "Choisir", "Scegli", "Escolher", "选取", "選擇"],
        rationale: "The chooser's commit control, matched by AXButton title. Korean read live 2026-09-15 beside `취소` and `기존 프로젝트 열기…` in the same census (#885). ja-JP and de-DE were unmeasured as of that date -- superseded below."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Choose#value"
    )

    static let projectChooserEmptyProjectLabel = LabelSet(
        canonical: "Empty Project",
        variants: ["비어 있는 프로젝트", "空のプロジェクト", "Leeres Projekt", "Proyecto vacío", "Projet vide", "Progetto vuoto", "Projeto Vazio", "空项目", "空白計畫案"],
        rationale: "The Empty Project tile's label, read as an AXStaticText value after selecting the `새로운 프로젝트` category. Korean read live 2026-09-15 (#885); the details panel alongside it read `비어 있는 프로젝트 생성`, which is how the selection is confirmed without a coordinate. ja-JP and de-DE were unmeasured as of that date -- superseded below."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Empty%20Project#value"
    )

    static let newProjectMenuItem = LabelSet(
        canonical: "New",
        variants: ["신규", "新規", "Neu", "Nuevo", "Nouveau", "Nuovo", "Novo", "新建", "新增"],
        rationale: "Reveals the New Project chooser, or creates the project directly where Logic skips it. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/New%23mti#value"
    )

    /// #369: File > Export. Both forms were read from Logic's File menu; no other locale has been
    /// measured for this submenu, so callers must refuse rather than translate or guess one.
    /// The application menu-bar item. The product NAME is not translated, but its SPACE is, and NOT
    /// along the lines anyone would guess: en-US and ja-JP spell it `Logic Pro` with U+0020, while
    /// ko-KR and de-DE spell it `Logic\u{00A0}Pro` with a NON-BREAKING space. A literal
    /// `"Logic Pro"` therefore matches nothing on a Korean or German Logic, and a menu walk that
    /// starts there silently finds no Control Surfaces submenu — a wall that reads as a missing
    /// feature rather than as a missing character. Measured on all four navigation-free censuses;
    /// the first draft of this comment asserted Korean used U+0020 and the census said otherwise.
    static let applicationMenuBarItem = LabelSet(
        canonical: "Logic Pro",
        variants: ["Logic\u{00A0}Pro"],
        rationale: "MEASURED on all four navigation-free censuses, reading the AXMenuBarItem title: en-US 2026-09-12 and ja-JP 2026-09-05 read `Logic Pro` (U+0020); ko-KR 2026-09-05 and de-DE 2026-09-12 read `Logic\u{00A0}Pro` (U+00A0). Menu-bar items publish no AXIdentifier, so the title is the only handle."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Logic%20Pro#value"
    )

    // MARK: - Control Surface Setup (#884 / #862)
    //
    // Logic ships with NO control surface installed, and until one is, every MCU send this server
    // makes is discarded silently: `logic_system health` still reports `mcu.connected: true`
    // because that flag is set by ANY inbound traffic rather than by a handshake reply. Installing
    // the device is a GUI-only route, so these labels exist to drive it without English literals.
    //
    // The menu-path labels below are measured on BOTH en-US and ko-KR, from the navigation-free
    // censuses of 2026-09-12 and 2026-09-05 respectively. The Setup WINDOW's own labels are read
    // live on ko-KR only (2026-09-15, Logic 12.3 build 6674); their `canonical` is Apple's English
    // and is NOT measured on this host, which is why each rationale says so rather than implying a
    // reading nobody took.

    static let controlSurfacesMenuItem = LabelSet(
        canonical: "Control Surfaces",
        variants: ["컨트롤 서피스", "コントロールサーフェス", "Bedienoberflächen", "Superficies de control", "Surfaces de contrôle", "Superfici di controllo", "Superfícies de Controle", "控制表面"],
        rationale: "The `Logic Pro` menu's Control Surfaces submenu parent, matched by AXMenuItem title. All four spellings are MEASURED at AXMenuBar/AXMenuBarItem[Logic Pro]/AXMenu/AXMenuItem: en-US `Control Surfaces` and de-DE `Bedienoberflächen` in the 2026-09-12 navigation-free censuses, ko-KR `컨트롤 서피스` and ja-JP `コントロールサーフェス` in the 2026-09-05 ones."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Control%20Surfaces#value"
    )

    /// WARNING -- this string is NOT unique inside its own submenu on ko-KR OR ja-JP. The Control
    /// Surfaces submenu holds `Setup…` and `Settings…` as adjacent items; Korean renders both as
    /// `설정…` and Japanese renders both as `設定…`, and both carry the identical AXIdentifier
    /// `globalMenuItemCall:`, so neither the title nor the identifier separates them. Measured
    /// 2026-09-05 (ko-KR, ja-JP) against 2026-09-12 (en-US, de-DE); German is the only measured
    /// locale where the two differ (`Setup …` against `Einstellungen …`).
    /// A caller must therefore press a candidate and then IDENTIFY THE WINDOW THAT APPEARED --
    /// `Setup…` opens `controlSurfaceSetupWindowTitle`, `Settings…` opens a preferences dialog --
    /// and fall through to the other candidate when the wrong one opened. Choosing by ordinal is
    /// exactly the positional targeting this repository refuses.
    static let controlSurfaceSetupMenuItem = LabelSet(
        canonical: "Setup…",
        variants: ["설정…", "設定…", "Setup …", "Configuración…", "Configuration…", "Configurazione…", "Configuração…", "设置…", "設定⋯"],
        rationale: "Opens the Control Surface Setup window. MEASURED in all four locales at AXMenuItem[Control Surfaces]/AXMenu: en-US `Setup…`, ko-KR `설정…`, ja-JP `設定…`, de-DE `Setup …` (U+0020 before the ellipsis, unlike en-US). Collides with `Settings…` on ko-KR AND ja-JP -- see the doc comment. German does not collide."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Setup%E2%80%A6#value"
    )

    /// The sibling this server must NOT mistake for `Setup…`. Present only so the collision is
    /// nameable in code and in a failure hint; nothing selects by it.
    static let controlSurfaceSettingsMenuItem = LabelSet(
        canonical: "Settings…",
        variants: ["설정…", "設定…", "Einstellungen …", "Ajustes…", "Réglages…", "Impostazioni…", "设置…", "設定⋯"],
        rationale: "The global control-surface preferences item, adjacent to `Setup…`. MEASURED in all four locales: en-US `Settings…`, ko-KR `설정…`, ja-JP `設定…`, de-DE `Einstellungen …`. Its ko-KR and ja-JP spellings are identical to `Setup…`, which is the whole reason the setup drive identifies its window rather than its menu item."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Settings%E2%80%A6#value"
    )

    static let controlSurfaceSetupWindowTitle = LabelSet(
        canonical: "Control Surface Setup",
        variants: ["컨트롤 서피스 설정", "コントロールサーフェス設定", "Bedienoberflächen-Setup", "Configuración de superficies de control", "Configuration de la surface de contrôle", "Configurazione superfici di controllo", "Configuração de Superfície de Controle", "控制表面设置", "控制表面設定"],
        rationale: "Identifies the Setup window by AXWindow title; this is the reading that disambiguates the two ko-KR `설정…` items. ko-KR `컨트롤 서피스 설정` read live 2026-09-15 on Logic 12.3 (6674). The English canonical is Apple's documented title and is NOT measured on this host. ja-JP and de-DE unmeasured."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Control%20Surface%20Setup#value"
    )

    static let controlSurfaceNewMenuButton = LabelSet(
        canonical: "New",
        variants: ["신규", "新規", "Neu", "Nuevo", "Nouveau", "Nuovo", "Novo", "新建", "新增"],
        rationale: "The Setup window's OWN menu button -- an AXMenuButton with subrole AXSegment carrying this string in AXDescription, not AXTitle, and living inside the window rather than in the application menu bar. An earlier probe enumerated only the menu bar and the window's AXButtons and concluded no install route existed; it was reading the wrong two places. ko-KR read live 2026-09-15. English canonical unmeasured on this host."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/New%23mti#value"
    )

    static let controlSurfaceInstallMenuItem = LabelSet(
        canonical: "Install…",
        variants: ["설치…", "インストール…", "Installieren …", "Instalar…", "Installer…", "Installa…", "安装…", "安裝⋯"],
        rationale: "First item of the Setup window's `New` menu, beside `Scan All Models` and `Automatic Installation`. ko-KR `설치…` read live 2026-09-15 with siblings `모든 모델 스캔` and `자동 설치`. English canonical unmeasured on this host."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Install%E2%80%A6#value"
    )

    static let controlSurfaceInstallWindowTitle = LabelSet(
        canonical: "Install",
        variants: ["설치", "インストール", "Installieren", "Instalar", "Installer", "Installa",
                   "Instalação", "安装", "安裝"],
        rationale: "The device picker opened by the Install menu item; an AXFloatingWindow holding a"
            + " 144-row AXTable of manufacturer/model/profile/version. Apple's own Install nib keys"
            + " the window `164.title`. The ko value was read live 2026-09-15. Anchored at ko for the"
            + " same reason as the Add button: the row has no `en` on the `strings` side and English"
            + " lives in `nibstrings`.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FInstall.strings/ko/164.title#value"
    )

    static let controlSurfaceAddButton = LabelSet(
        canonical: "Add",
        variants: ["추가", "追加", "Hinzufügen", "Añadir", "Ajouter", "Aggiungi", "Adicionar", "添加",
                   "加入"],
        rationale: "Commits the Install window's selected row. Apple's own Install nib keys this button"
            + " `100173.title`, which is the row that MEANS this control -- `Add` also resolves in"
            + " Localizable.strings and in three MA frameworks, and none of those is this button. The"
            + " ko value is what was read live 2026-09-15 beside the scan buttons. The reference names"
            + " the `strings` side ANCHORED AT ko because the row has no `en` there; English lives in"
            + " `nibstrings` under the same key, the split #895 established, so `Add` itself is the"
            + " one member this derivation does not verify.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FInstall.strings/ko/100173.title#value"
    )

    static let controlSurfaceOutputPortLabel = LabelSet(
        canonical: "Output Port",
        variants: ["출력 포트", "出力ポート", "Output-Port", "Puerto de salida", "Port de sortie", "Porta di uscita", "Porta de saída", "输出端口", "輸出埠"],
        rationale: "Labels the popup carrying the device's MIDI destination. The label and the control are"
            + " siblings, which is how the popup is found without an index. Apple's row; the ko value"
            + " was read live 2026-09-15. The colon is drawn by the form and not stored (`field_label`"
            + " in docs/canon/DECORATION-RULES.json), so the match is `.prefix`.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Output%20Port#value"
    )

    static let controlSurfaceInputPortLabel = LabelSet(
        canonical: "Input Port",
        variants: ["입력 포트", "入力ポート", "Input-Port", "Puerto de entrada", "Port d’entrée", "Porta di ingresso", "Porta de entrada", "输入端口", "輸入埠"],
        rationale: "Labels the popup carrying the device's MIDI source. It defaults to the ALL-sources"
            + " value after an install, which already includes this server's port -- so a run that"
            + " only checks the input port can read as bound while the output port is still off and"
            + " nothing reaches Logic. Apple's row; the ko value was read live 2026-09-15. The colon"
            + " is drawn by the form and not stored (`field_label` in"
            + " docs/canon/DECORATION-RULES.json), so the match is `.prefix`.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Input%20Port#value"
    )

    static let controlSurfaceModelLabel = LabelSet(
        canonical: "Model",
        variants: ["모델", "モデル", "Modell", "Modelo", "Modèle", "Modello", "Modelo", "型号", "模型"],
        rationale: "Labels the AXStaticText naming the installed device model, which is how this server"
            + " confirms an install landed rather than trusting the Add button's return code. Apple's"
            + " row; the ko value is what was read live 2026-09-15 beside `Mackie Control`. The window"
            + " DRAWS the trailing colon -- docs/canon/DECORATION-RULES.json says a `field_label` may"
            + " carry `:` and Logic's table holds the bare name -- so the comparison is `.prefix` and"
            + " this set carries Apple's bytes rather than nine hand-typed spellings with a colon"
            + " stuck on.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Model#value"
    )

    static let exportMenuItem = LabelSet(
        canonical: "Export",
        variants: ["내보내기", "書き出す", "Exportieren", "Exportar", "Exporter", "Esporta", "导出", "輸出"],
        rationale: "File submenu title measured in English and Korean; a locale without one of these labels is refused as an unmeasured stem-export menu label. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at File > Export. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Export%23mti#value"
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
        variants: ["모든 트랙을 오디오 파일로…", "すべてのトラックをオーディオファイルとして…", "Alle Spuren als Audiodateien …", "Todas las pistas como archivos de audio…", "Toutes les pistes en fichiers audio…", "Tutte le tracce come file audio…", "Todas as Pistas como Arquivos de Áudio…", "所有轨道为音频文件…", "所有音軌為音訊檔案⋯"],
        rationale: "Measured all-tracks audio-file export leaf: EN uses `All Tracks` against singular/Selected entries; KO uses `모든 트랙을` against `1개의 트랙을` and `선택 범위를`. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at File > Export > All Tracks as Audio Files…. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/All%20Tracks%20as%20Audio%20Files%E2%80%A6#value"
    )

    /// #369: controls inside the per-track stem-export panel. The panel's own
    /// window title is the OS Open-panel string, so it is not a usable signal.
    static let oneFilePerTrackPopupValue = LabelSet(
        canonical: "One File per Track",
        variants: ["트랙당 하나의 파일", "トラックごとに1ファイル", "Eine Datei pro Spur", "Un archivo por pista", "Un fichier par piste", "Un file per traccia", "Um Arquivo por Pista", "每个轨道一个文件", "每個音軌一個檔案"],
        rationale: "Measured from the live stem-export panel on 2026-09-01; the panel window title is the OS Open-panel string and is therefore not a usable signal."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FBounceInPlace.strings/en/7B5-NP-XpR.title#value"
    )

    static let stemExportCommitButton = LabelSet(
        canonical: "Export",
        variants: ["내보내기", "書き出す", "Exportieren", "Exportar", "Exporter", "Esporta", "导出", "輸出"],
        rationale: "Measured from the live stem-export panel on 2026-09-01; the panel window title is the OS Open-panel string and is therefore not a usable signal."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Export%23mti#value"
    )

    static let stemExportDismissButton = LabelSet(
        canonical: "Cancel",
        variants: ["취소", "キャンセル", "Abbrechen", "Cancelar", "Annuler", "Annulla", "取消"],
        rationale: "Measured from the live stem-export panel on 2026-09-01; the panel window title is the OS Open-panel string and is therefore not a usable signal."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FAddSelToArrange.strings/en/100050.title#value"
    )

    /// #369: The transient progress window title is rendered with an ordinary
    /// space in some locales and a NO-BREAK SPACE in Korean. Keep the measured
    /// product label in locale policy rather than scattering a literal through
    /// the export driver.
    static let stemExportProgressWindowTitle = LabelSet(
        canonical: "Logic Pro",
        variants: [],
        rationale: "Measured on the live Korean progress dialog on 2026-09-02 as `Logic\\u{00A0}Pro`; whitespace is normalized only for this product-title rendering."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Logic%20Pro#value"
    )

    static func progressWindowTitleMatches(_ title: String) -> Bool {
        let normalized = String(title.map { $0.isWhitespace ? " " : $0 })
        return stemExportProgressWindowTitle.matches(normalized)
    }

    static let editMenuBar = LabelSet(
        canonical: "Edit",
        variants: ["편집", "編集", "Bearbeiten", "Edición", "Édition", "Modifica", "Editar", "编辑", "編輯"],
        rationale: "Undo is menu-only in the rollback path; post-undo inventory readback verifies outcome. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires. Extended on 2026-09-16 from the row Apple keys this menu title under -- Apple suffixes menu titles `#mti` and all 48 such keys carry all ten locales -- so every language Logic ships is covered. The reference and its value are cited in docs/observations/2026-09-16-seven-languages-reported-unknown.json. The variants read off running Logics before this change are each one of that row's own values -- nothing measured was dropped, and nothing was typed.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Edit%23mti#value"
    )

    /// #304: Edit > Tempo > Show Tempo List. These are the only Tempo-menu labels this surface
    /// may actuate. They were read from a live Korean Logic Pro 12.3 on 2026-09-02, where the
    /// complete path was `편집 > 템포 > 템포 목록 보기` and opened a fully-classified AXTable.
    /// English is the canonical identity; any locale other than the measured English/Korean pair
    /// is refused by `TempoMapAX` before it tries this path.
    static let tempoMenuItem = LabelSet(
        canonical: "Tempo",
        variants: ["템포", "テンポ", "Ritmo", "Andamento", "速度", "拍速"],
        rationale: "Measured 2026-09-02 on live Logic Pro 12.3 ko-KR as the Edit-menu submenu `템포`."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Tempo%23mti#value"
    )

    static let showTempoListMenuItem = LabelSet(
        canonical: "Show Tempo List",
        variants: ["템포 목록 보기", "Tempoliste einblenden", "テンポリストを表示", "Mostrar lista de tempo", "Afficher la liste du tempo", "Mostra “Elenco ritmo”", "Mostrar Lista de Andamentos", "显示速度列表", "顯示拍速列表"],
        rationale: "Measured 2026-09-02 on live Logic Pro 12.3 ko-KR: opens the Tempo List table. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Show%20Tempo%20List#value"
    )

    /// The Tempo List's independent count witness. On the measured Korean build its AXStaticText
    /// has AXDescription `항목 수` and value `1개의 이벤트`; the reader compares that count with
    /// the AXRow count and refuses a disagreement rather than publishing a shorter list.
    static let tempoListNumberOfItemsLabel = LabelSet(
        canonical: "Number of Items",
        variants: ["항목 수", "項目数", "Anzahl der Objekte", "Número de ítems", "Nombre d’éléments", "Numero di elementi", "Número de Itens", "项目数", "項目數量"],
        rationale: "Measured 2026-09-02 on live Logic Pro 12.3 ko-KR as AXDescription `항목 수` on the Tempo List event-count AXStaticText."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Number%20of%20Items#value"
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
        variants: ["탐색", "移動", "Navigieren", "Navegar", "Naviguer", "Navigazione", "浏览", "導覽"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires. Extended on 2026-09-16 from the row Apple keys this menu title under -- Apple suffixes menu titles `#mti` and all 48 such keys carry all ten locales -- so every language Logic ships is covered. The reference and its value are cited in docs/observations/2026-09-16-seven-languages-reported-unknown.json. The variants read off running Logics before this change are each one of that row's own values -- nothing measured was dropped, and nothing was typed.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Navigate%23mti#value"
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
        variants: ["트랙", "トラック", "Spur", "Pista", "Piste", "Traccia", "轨道", "音軌"],
        rationale: "Top-level menu titles expose no stable AXIdentifier in Logic. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires. Extended on 2026-09-16 from the row Apple keys this menu title under -- Apple suffixes menu titles `#mti` and all 48 such keys carry all ten locales -- so every language Logic ships is covered. The reference and its value are cited in docs/observations/2026-09-16-seven-languages-reported-unknown.json. The variants read off running Logics before this change are each one of that row's own values -- nothing measured was dropped, and nothing was typed.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Track%23mti#value"
    )

    /// #448 — Track > Sort Tracks By. Measured on 2026-09-02 on Logic Pro
    /// 12.3 with a Korean UI as `트랙 › 트랙을 다음으로 정렬`. The menu bar is
    /// only partly localized, so this policy deliberately has no inferred EN/JA
    /// form: a locale without this measurement must refuse.
    static let sortTracksByMenuItem = LabelSet(
        canonical: "트랙을 다음으로 정렬",
        variants: ["Sort Tracks by", "トラックを並べ替える", "Spuren sortieren nach", "Ordenar pistas por", "Trier les pistes par", "Ordina tracce per", "轨道排序方式", "按以下方式排列音軌"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3: Track > Sort Tracks By submenu title. No other locale is measured; never translate this menu label."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Sort%20Tracks%20by#value"
    )

    static let sortTracksMenuPath = MenuPath(
        bar: trackMenuBar,
        item: sortTracksByMenuItem
    )

    static let sortTracksByMIDIChannelMenuItem = LabelSet(
        canonical: "MIDI 채널",
        variants: ["MIDI Channels", "MIDIチャンネル", "MIDI-Kanäle", "Canales MIDI", "Canaux MIDI", "Canali MIDI", "Canais de MIDI", "MIDI 通道", "MIDI 聲道"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3 as a Track > Sort Tracks By leaf; no other locale is measured."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/MIDI%20Channels%23mti#value"
    )

    static let sortTracksByAudioChannelMenuItem = LabelSet(
        canonical: "오디오 채널",
        variants: ["Audio Channel", "オーディオチャンネル", "Audiokanal", "Canal de audio", "Canal audio", "Canale audio", "Canal de Áudio", "音频通道", "聲道"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3 as a Track > Sort Tracks By leaf; no other locale is measured."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Audio%20Channel#value"
    )

    static let sortTracksByOutputChannelMenuItem = LabelSet(
        canonical: "출력 채널",
        variants: ["Output Channel", "出力チャンネル", "Output-Kanal", "Canal de salida", "Canal de sortie", "Canale di uscita", "Canal de Saída", "输出通道", "輸出聲道"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3 as a Track > Sort Tracks By leaf; no other locale is measured."
            + " Extended on 2026-09-18 to every locale Logic ships by reading the row Apple keys this control, the same row its siblings `sortTracksByInstrumentNameMenuItem` and `sortTracksByUsedMenuItem` were derived from on 2026-09-16; those two were extended and these three were left behind, so the Korean canonical was the ONLY value and the menu could not be found in English. Nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Output%20Channel#value"
    )

    static let sortTracksByInstrumentNameMenuItem = LabelSet(
        canonical: "악기 이름",
        variants: ["Instrument Names", "音源名", "Instrumentennamen", "Nombres de instrumento", "Noms des instruments", "nomi strumenti", "Nomes dos Instrumentos", "乐器名称", "樂器名稱"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3 as a Track > Sort Tracks By leaf; no other locale is measured."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Instrument%20Names%23acc#value"
    )

    static let sortTracksByTrackNameMenuItem = LabelSet(
        canonical: "트랙 이름",
        variants: ["Track Name", "トラック名", "Spurname", "Nombre de pista", "Nom de la piste", "Nome traccia", "Nome da Pista", "轨道名称", "音軌名稱"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3 as a Track > Sort Tracks By leaf; no other locale is measured."
            + " Extended on 2026-09-18 to every locale Logic ships by reading the row Apple keys this control, the same row its siblings `sortTracksByInstrumentNameMenuItem` and `sortTracksByUsedMenuItem` were derived from on 2026-09-16; those two were extended and these three were left behind, so the Korean canonical was the ONLY value and the menu could not be found in English. Nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Track%20Name#value"
    )

    static let sortTracksByUsedMenuItem = LabelSet(
        canonical: "사용 여부",
        variants: ["Used, Unused", "使用、不使用", "Benutzt, Unbenutzt", "En uso, Sin usar", "Utilisé/Inutilisé", "Usate, non usate", "Usadas, Não Usadas", "已使用, 未使用", "已使用、未使用"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3 as a Track > Sort Tracks By leaf; no other locale is measured."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Used%2C%20Unused#value"
    )

    static let sortTracksByCreationDateMenuItem = LabelSet(
        canonical: "생성일",
        variants: ["Creation Date", "作成日", "Erstellungsdatum", "Fecha de creación", "Date de création", "Data di creazione", "Data de Criação", "创建日期", "製作日期"],
        rationale: "Measured 2026-09-02 on Korean Logic Pro 12.3 as a Track > Sort Tracks By leaf; no other locale is measured."
            + " Extended on 2026-09-18 to every locale Logic ships by reading the row Apple keys this control, the same row its siblings `sortTracksByInstrumentNameMenuItem` and `sortTracksByUsedMenuItem` were derived from on 2026-09-16; those two were extended and these three were left behind, so the Korean canonical was the ONLY value and the menu could not be found in English. Nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Creation%20Date#value"
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
    ///
    /// The Korean label was corrected on 2026-09-03 after reading the File menu off a live Logic
    /// 12.3 running in Korean. The item is `별도 저장…`; the string carried here before,
    /// `다른 이름으로 저장…`, is in no menu of that build, so `save_as` refused every call with
    /// `element_not_found`. Byte-exact, in menu order:
    ///
    ///     저장                eca080ec9ea5
    ///     별도 저장…          ebb384eb8f8420eca080ec9ea5e280a6   <- this item
    ///     복사본 별도 저장…   ebb3b5ec82acebb3b820ebb384eb8f84…  <- Save a Copy As…
    ///     템플릿으로 저장…    ed859ced948ceba6bfec9cbceba19c20…  <- Save as Template…
    ///
    /// The neighbour `복사본 별도 저장…` CONTAINS this item's label, so the exact-match discipline
    /// is load-bearing: a prefix or contains match would save a copy instead. The unmeasured
    /// string is not kept as a second variant — nobody has seen it in any build, and an untested
    /// guess in a LabelSet is what this defect was.
    static let saveAsMenuItem = LabelSet(
        canonical: "Save As…",
        variants: ["별도 저장…", "別名で保存…", "Sichern unter …", "Guardar como…", "Enregistrer sous…", "Salva come…", "Salvar como…", "保存为…", "儲存為⋯"],
        rationale: "File menu entry that opens the Save panel; the panel is the only path to save_as. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at File > Save As…. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FKeyCommands.strings/en/300622.title#value"
    )

    /// #747: the Save panel's own window title, and the two "Organize my project as" radios inside
    /// it. Measured 2026-09-03 on a live Logic 12.3 in Korean by opening `파일 > 별도 저장…` and
    /// enumerating the panel: it is an `AXWindow` with subrole `AXDialog` titled `저장`, carrying
    /// exactly one filename field, one enabled save button, one cancel button, and two
    /// `AXRadioButton`s titled `패키지` and `폴더`.
    ///
    /// The classifier that recognises this panel compared all three against English literals, so on
    /// a Korean Logic it enumerated the right window and rejected it — `save_as` refused with
    /// `element_not_found` after the panel was already on screen.
    static let savePanelWindowTitle = LabelSet(
        canonical: "Save",
        variants: ["저장", "保存", "Sichern", "Guardar", "Enregistrer", "Salva", "Salvar", "儲存"],
        rationale: "Title of the Save As panel window; the structural classifier matches it exactly."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FEXSKeyActions.strings/en/110.title#value"
    )

    /// #747: the `Package` radio in the Save panel. See `savePanelWindowTitle`.
    static let savePanelPackageRadio = LabelSet(
        canonical: "Package",
        variants: ["패키지", "パッケージ", "Paket", "Paquete", "Paquet", "Pacchetto", "Pacote", "包", "套件"],
        rationale: "One of the two project-organisation radios that identify the Save As panel."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FSaveAsOptionsView.strings/en/Zb7-X8-NPE.title#value"
    )

    /// #747: the `Folder` radio in the Save panel. See `savePanelWindowTitle`.
    static let savePanelFolderRadio = LabelSet(
        canonical: "Folder",
        variants: ["폴더", "フォルダ", "Ordner", "Carpeta", "Dossier", "Cartella", "Pasta", "文件夹", "檔案夾"],
        rationale: "One of the two project-organisation radios that identify the Save As panel."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Folder%23mti#value"
    )

    /// #519: File > Bounce.
    static let bounceMenuItem = LabelSet(
        canonical: "Bounce",
        variants: ["바운스", "バウンス", "Bouncen", "Renderizar", "并轨", "併軌"],
        rationale: "File menu entry that opens the Bounce dialog; menu-only in the AppleScript bounce path. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at File > Bounce. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `StrToolbItemName` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrToolbItemName%7C%7C%7CBounce#value"
    )

    /// #519: the Bounce submenu's "Project or Section…" leaf. Both the curly-ellipsis (`…`) and
    /// literal three-dot (`...`) renderings have been observed across Logic builds, in both
    /// locales, so all four spellings are kept rather than assuming one glyph.
    static let projectOrSectionMenuItem = LabelSet(
        canonical: "Project or Section…",
        variants: ["프로젝트 또는 섹션…", "Project or Section...", "프로젝트 또는 섹션...", "プロジェクトまたは選択範囲…", "Projekt oder Abschnitt …"],
        rationale: "Bounce dialog's menu-driven entry point; multiple ellipsis renderings observed across Logic builds. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at File > Bounce > Project or Section…. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
    )

    /// #519: File > Import.
    static let importMenuItem = LabelSet(
        canonical: "Import",
        variants: ["가져오기", "読み込む", "Importieren", "Importar", "Importer", "Importa", "导入", "輸入"],
        rationale: "File menu entry that opens the Import submenu used by midi.import_file. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Import%23mti#value"
    )

    /// #519: File > Import > MIDI File….
    /// The title of Logic's MIDI-import open panel, used to tell that panel APART from the tempo
    /// alert that can follow an import.
    ///
    /// It was two literals in the AppleScript — `name is not "Import" and name is not "가져오기"` —
    /// and on a German Logic that test is TRUE of the import panel itself, so the still-open panel
    /// was taken for the tempo dialog and dismissed as one. `Importieren` was read off the product's
    /// own refusal on 2026-09-12 (#876), which reported `dialog_title: "Importieren"` while refusing
    /// `record_sequence` for a blocking dialog.
    ///
    /// This is still a NEGATIVE identification and that is the weaker half: it says which window is
    /// not the tempo alert rather than which one is. Positively identifying the tempo alert needs
    /// that alert measured on each locale, which has not been done.
    /// The button that commits Logic's MIDI-import open panel.
    ///
    /// German is DELIBERATELY ABSENT. The panel's own title was read off the product's refusal
    /// envelope; the button inside it was not, and a button label is not derivable from a window
    /// title — English spells both `Import`, and that coincidence is exactly what would make a
    /// guess look right until it silently clicked the wrong control. With no German variant the
    /// import fails to find its button and says so, which is the honest outcome until somebody
    /// opens that panel on a German Logic and reads it.
    static let midiImportCommitButton = LabelSet(
        canonical: "Import",
        variants: ["가져오기", "Importieren", "読み込む", "Importar", "Importer", "Importa", "导入", "輸入"],
        rationale: "The commit button of Logic's MIDI-import open panel. German read 2026-09-13 by OPENING the panel on a de-DE Logic and enumerating its buttons: `Abbrechen` and `Importieren`, the latter disabled until a file is chosen. It does share the panel's title — which is why it was held back until somebody looked rather than inferred from the window name."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Import%23mti#value"
    )

    /// The button that DECLINES Logic's "import the tempo too?" alert after a MIDI import.
    ///
    /// Measured 2026-09-13 on a de-DE Logic by reading the alert (#876): it carries NO window name
    /// at all, its text is `Auch Tempo-Informationen importieren?`, and its buttons are `Nein`,
    /// `Tempo importieren` and `Abbrechen`. Declining is the only correct answer here — importing a
    /// file's tempo would rewrite the project's tempo map, which is a mutation the caller did not
    /// ask for and this operation cannot undo.
    ///
    /// `Abbrechen` is deliberately NOT a variant. Cancelling the alert is not the same as declining
    /// it, and a set that held both would let the wrong one be pressed first.
    static let midiImportDeclineTempoButton = LabelSet(
        canonical: "No",
        variants: ["아니요", "Nein", "いいえ", "Non", "Não", "否"],
        rationale: "Declines the post-import tempo alert so a MIDI import cannot rewrite the project's tempo map. German read 2026-09-13 off the live alert, whose buttons are `Nein` / `Tempo importieren` / `Abbrechen`."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/No#value"
    )

    /// The alert's own question text, which is how it can be identified POSITIVELY.
    ///
    /// The alert carries no window name, so the code that found it asked which AXDialog was *not*
    /// the import panel. That is a negative identification: on a German Logic it matched the import
    /// panel itself until the panel's title was measured, and it would match any other unnamed
    /// dialog Logic happens to raise. The question text is the thing that says this IS the tempo
    /// alert. Matched by containment because the rest of the alert is a paragraph of explanation.
    static let midiImportTempoAlertText = LabelSet(
        canonical: "tempo",
        variants: ["템포", "Tempo-Informationen"],
        rationale: "Positively identifies the post-import tempo alert, which exposes no window name. German text read 2026-09-13: `Auch Tempo-Informationen importieren?`. Callers match it by CONTAINMENT — the alert's body is a paragraph, and the question is one phrase inside it."
    )

    static let midiImportPanelTitle = LabelSet(
        canonical: "Import",
        variants: ["가져오기", "Importieren", "読み込む", "Importar", "Importer", "Importa", "导入", "輸入"],
        rationale: "Distinguishes Logic's MIDI-import open panel from the tempo alert that may follow it; both carry subrole AXDialog, so the title is the only separator available. German read 2026-09-12 from the product's own refusal envelope (#876), which named the blocking dialog `Importieren`."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Import%23mti#value"
    )

    static let midiFileMenuItem = LabelSet(
        canonical: "MIDI File…",
        variants: ["MIDI 파일…", "MIDIファイル…", "MIDI-Datei …", "Archivo MIDI…", "Fichier MIDI…", "File MIDI…", "Arquivo de MIDI…", "MIDI 文件…", "MIDI 檔案⋯"],
        rationale: "Import submenu leaf that opens the MIDI file chooser for midi.import_file. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/MIDI%20File%E2%80%A6#value"
    )

    /// #519: Edit > Move.
    static let moveMenuItem = LabelSet(
        canonical: "Move",
        variants: ["이동", "Bewegen", "移動", "Trasladar", "Déplacer", "Sposta", "Mover", "移动"],
        rationale: "Edit menu entry that opens the Move submenu used to reposition a selected region. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Move#value"
    )

    /// #519: Edit > Move > To Playhead.
    static let toPlayheadMenuItem = LabelSet(
        canonical: "To Playhead",
        variants: ["재생헤드로", "Für Abspielposition", "再生ヘッド位置に", "Al cursor de reproducción", "Vers la tête de lecture", "Sulla testina di riproduzione", "Para o Cursor de Reprodução", "到播放头", "至播放磁頭"],
        rationale: "Move submenu leaf that repositions the selected region to the playhead. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/To%20Playhead#value"
    )

    /// #519: Navigate > Set Locators….
    /// `Navigate > Set Locators…`, in every language Logic ships, with and without the ellipsis.
    ///
    /// Two of the ten before this: `Set Locators…` and `로케이터 설정…`, both carrying U+2026, and
    /// the ellipsis is why the row was never found -- Apple ships `Set Locators` with no ellipsis
    /// in ten locales and ships NO row with one. It does ship ellipses elsewhere when a menu item
    /// opens a dialog (`Set Left Locator numerically…`, ko `숫자로 왼쪽 로케이터 설정…`), so their
    /// absence here is a fact about this string rather than about the resource format.
    ///
    /// That leaves a question nobody can answer without opening the Navigate menu, which is a
    /// recorded wedge risk on a live session: either the item really is `Set Locators` and the
    /// ellipsis this product has always carried is wrong, or macOS renders one the resource does
    /// not contain.
    ///
    /// The first version of this change answered it by carrying BOTH forms in all ten -- and the
    /// ratchet refused, correctly. Appending U+2026 to nine of Apple's values INVENTS nine
    /// strings: `Locator-Punkte setzen…` is not a value Logic ships, it is one this file made up,
    /// and `POLICY-LITERALS`'s list of literals answered nowhere may only shrink. So the ten
    /// derived values go in as they are, the two ellipsis forms that were already here stay
    /// because they are already on that list, and the eight languages whose menu might render an
    /// ellipsis stay open. Closing them needs somebody to read the menu, not somebody to type.
    ///
    /// The row is the TOOLBAR item's, `StrToolbItemName|||Set Locators`. The Navigate menu item
    /// has no row of its own in the corpus; `ActionBarCustomization.strings/100247.title` carries
    /// the same ten values, so the substitution changes no string and is named here rather than
    /// hidden.
    static let setLocatorsMenuItem = LabelSet(
        canonical: "Set Locators…",
        variants: ["Set Locators", "로케이터 설정", "ロケータを設定", "Locator-Punkte setzen", "Fijar localizadores", "Placer les locators", "Imposta localizzatori", "Definir Localizadores", "设定定位符", "設定定位點", "로케이터 설정…"],
        rationale: "Navigate > Set Locators, resolved by exact menu-item name. Derived from the row Apple keys the toolbar item under, carried beside the two ellipsis forms that predate this change; the other eight ellipsis renderings are NOT invented here, because appending one to a value Apple ships produces a string Apple does not. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrToolbItemName%7C%7C%7CSet%20Locators#value"
    )

    /// #519: Navigate > Go To. Korean Logic renders this the same `이동` string as Edit > Move
    /// (`moveMenuItem`) — the two LabelSets deliberately share that surface form under different
    /// English canonicals; each is scoped to its own menu bar by the caller's resolved parent
    /// specifier, so the shared Korean text never crosses into the wrong menu.
    static let goToMenuItem = LabelSet(
        canonical: "Go To",
        variants: ["이동", "移動", "Gehe zu", "Ir a", "Aller à", "Vai a", "Ir para", "前往"],
        rationale: "Navigate menu entry that opens the Go To submenu used by goto_position. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Go%20To#value"
    )

    /// #519: Navigate > Go To > Position….
    static let goToPositionMenuItem = LabelSet(
        canonical: "Position…",
        variants: ["위치…", "位置…", "Position …", "Posición…", "Posizione…", "Posição…", "位置⋯"],
        rationale: "Go To submenu leaf that opens the Go To Position dialog. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Position%E2%80%A6#value"
    )

    /// #519: Navigate > Open Marker List.
    static let openMarkerListMenuItem = LabelSet(
        canonical: "Open Marker List",
        variants: ["마커 목록 열기", "マーカーリストを開く", "Marker-Liste öffnen", "Abrir lista de marcadores", "Ouvrir la liste des marqueurs", "Apri elenco marcatori", "打开标记列表", "打開標記列表"],
        rationale: "Navigate menu entry that opens the Marker List window. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Open%20Marker%20List#value"
    )

    /// #519: Navigate > Create Marker.
    static let createMarkerMenuItem = LabelSet(
        canonical: "Create Marker",
        variants: ["마커 생성", "マーカーを作成", "Marker erzeugen", "Crear marcador", "Créer un marqueur", "Crea marcatore", "Criar Marcador", "创建标记", "製作標記"],
        rationale: "Navigate menu entry that creates a marker at the playhead. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `StrToolbItemName` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrToolbItemName%7C%7C%7CCreate%20Marker#value"
    )

    /// The Marker List toolbar's own Edit menu button, not the application menu bar.
    /// The marker-list Edit TOGGLE, whose AXDescription is the whole phrase rather than the verb.
    ///
    /// Added 2026-09-16 (#892). `markerTextAreaToggle` compared against `edit marker` and
    /// `마커 편집` inline -- two of the ten languages Logic ships, so the toggle was unfindable in
    /// the other eight and the rename path had no way to say why. Every string here is a value
    /// Apple ships at the row named below; nothing was translated by hand.
    /// Track > New Software Instrument Track — the software-instrument leaf.
    ///
    /// Added 2026-09-16 (#892). `createTrackViaMenu` took `(korean:, english:)` and tried the
    /// Korean spelling first, so track creation worked in exactly two of the ten languages Logic
    /// ships and reported `Cannot find menu item` in the other eight. That is the report in #883.
    /// Every string here is a value Apple ships at the row below; the German carries a non-breaking
    /// space and the Traditional Chinese a U+22EF midline ellipsis, neither of which survives being
    /// typed.
    static let newSoftwareInstrumentTrackMenuItem = LabelSet(
        canonical: "New Software Instrument Track",
        variants: ["새로운 소프트웨어 악기 트랙", "新規ソフトウェア音源トラック", "Neue Spur für Software-Instrument", "Nueva pista de instrumento de software", "Nouvelle piste d’instrument logiciel", "Nuova traccia di strumento software", "Nova Pista de Instrumento de Software", "新建软件乐器轨道", "新增軟體樂器音軌"],
        rationale: "Track menu leaf for this track type, derived from the row Apple keys it under "
            + "so every language Logic ships is covered. Checked offline by "
            + "Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/New%20Software%20Instrument%20Track#value"
    )

    /// Track > New Audio Track — the audio leaf.
    ///
    /// Added 2026-09-16 (#892). `createTrackViaMenu` took `(korean:, english:)` and tried the
    /// Korean spelling first, so track creation worked in exactly two of the ten languages Logic
    /// ships and reported `Cannot find menu item` in the other eight. That is the report in #883.
    /// Every string here is a value Apple ships at the row below; the German carries a non-breaking
    /// space and the Traditional Chinese a U+22EF midline ellipsis, neither of which survives being
    /// typed.
    static let newAudioTrackMenuItem = LabelSet(
        canonical: "New Audio Track",
        variants: ["새로운 오디오 트랙", "新規オーディオトラック", "Neue Audiospur", "Nueva pista de audio", "Nouvelle piste audio", "Nuova traccia audio", "Nova Pista de Áudio", "新音频轨道", "新增音訊音軌"],
        rationale: "Track menu leaf for this track type, derived from the row Apple keys it under "
            + "so every language Logic ships is covered. Checked offline by "
            + "Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/New%20Audio%20Track#value"
    )

    /// Track > New Session Player SI Track… — the Session Player / Drummer leaf.
    ///
    /// Added 2026-09-16 (#892). `createTrackViaMenu` took `(korean:, english:)` and tried the
    /// Korean spelling first, so track creation worked in exactly two of the ten languages Logic
    /// ships and reported `Cannot find menu item` in the other eight. That is the report in #883.
    /// Every string here is a value Apple ships at the row below; the German carries a non-breaking
    /// space and the Traditional Chinese a U+22EF midline ellipsis, neither of which survives being
    /// typed.
    ///
    /// The German therefore appears TWICE, and the two differ only in two invisible characters. The
    /// first is Apple's row, with U+00A0 after `Session` and before `…`. The Track menu does not
    /// render it that way: its AXTitle on a German Logic 12.3 read 2026-09-26 has U+0020 in both
    /// places, and no `.strings` file in Logic's `de.lproj` carries that spelling. The menu match is
    /// exact, so with only the row the drummer create never found its item in German and fell
    /// through to a key command that created nothing (#883). The row stays, because it is what
    /// `derivedFrom` cites and what the offline check pins.
    static let newSessionPlayerTrackMenuItem = LabelSet(
        canonical: "New Session Player SI Track…",
        variants: ["새로운 Session Player SI 트랙…", "新規Session Playerソフトウェア音源トラック…", "Neue Session Player SI-Spur …", "Neue Session Player SI-Spur …", "Nueva pista SI de Session Player…", "Nouvelle piste SI Session Player…", "Nuova traccia SI Session Player…", "Nova Pista de IS de Session Player…", "新建伴奏乐手 SI 轨道…", "新增 Session Player SI 音軌⋯"],
        rationale: "Track menu leaf for this track type, derived from the row Apple keys it under "
            + "so every language Logic ships is covered. Checked offline by "
            + "Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/New%20Session%20Player%20SI%20Track%E2%80%A6#value"
    )

    /// Track > New External MIDI Track — the external MIDI leaf.
    ///
    /// Added 2026-09-16 (#892). `createTrackViaMenu` took `(korean:, english:)` and tried the
    /// Korean spelling first, so track creation worked in exactly two of the ten languages Logic
    /// ships and reported `Cannot find menu item` in the other eight. That is the report in #883.
    /// Every string here is a value Apple ships at the row below; the German carries a non-breaking
    /// space and the Traditional Chinese a U+22EF midline ellipsis, neither of which survives being
    /// typed.
    static let newExternalMIDITrackMenuItem = LabelSet(
        canonical: "New External MIDI Track",
        variants: ["새로운 외부 MIDI 트랙", "新規外部MIDIトラック", "Neue externe MIDI-Spur", "Nueva pista MIDI externa", "Nouvelle piste MIDI externe", "Nuova traccia MIDI esterno", "Nova Pista de MIDI Externa", "新外部 MIDI 轨道", "新增外部 MIDI 音軌"],
        rationale: "Track menu leaf for this track type, derived from the row Apple keys it under "
            + "so every language Logic ships is covered. Checked offline by "
            + "Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/New%20External%20MIDI%20Track#value"
    )

    /// Track > Rename Track, in every language Logic ships.
    ///
    /// Added 2026-09-16 (#892). The call site carried a three-element literal array -- English and
    /// two Korean spellings -- so the operation reached two of ten languages. `이름 변경` was
    /// carried beside the full phrase as a shorter Korean spelling; it is not one of this row's
    /// values and has been kept.
    static let renameTrackMenuItem = LabelSet(
        canonical: "Rename Track",
        variants: ["트랙 이름 변경", "トラック名を変更", "Spur umbenennen", "Renombrar pista", "Renommer la piste", "Rinomina traccia", "Renomear Pista", "给轨道重新命名", "重新命名音軌", "이름 변경"],
        rationale: "Track-menu leaf, derived from the row Apple keys it under so every language "
            + "Logic ships is covered. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Rename%20Track#value"
    )

    /// Track > Delete Track, in every language Logic ships.
    ///
    /// Added 2026-09-16 (#892). The call site carried a three-element literal array -- English,
    /// Korean and in one case Japanese -- so the operation reached three of ten languages. EXACT matching stays load-bearing: the same menu carries Delete Unused Tracks, whose
    /// Japanese ENDS WITH this one's, so containment would reach a different destructive command.
    static let deleteTrackMenuItem = LabelSet(
        canonical: "Delete Track",
        variants: ["트랙 삭제", "トラックを削除", "Spur löschen", "Eliminar pista", "Supprimer la piste", "Elimina traccia", "Apagar Pista", "删除轨道", "刪除音軌"],
        rationale: "Track-menu leaf, derived from the row Apple keys it under so every language "
            + "Logic ships is covered. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Delete%20Track#value"
    )

    static let markerEditToggle = LabelSet(
        canonical: "Edit Marker",
        variants: ["마커 편집", "マーカーを編集", "Marker bearbeiten", "edición de marcador",
                   "Modifier le marqueur", "Modifica marcatore", "Editar Marcador",
                   "编辑标记", "剪輯標記"],
        rationale: "The marker-list text-area toggle, read by AXDescription. Derived on 2026-09-16 "
            + "from the row Apple keys this control under, so every language Logic ships is "
            + "covered. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Edit%20Marker%23und#value"
    )

    static let markerListEditMenuButton = LabelSet(
        canonical: "Edit",
        variants: ["編集", "편집", "Bearbeiten", "Edición", "Édition", "Modifica", "Editar", "编辑", "編輯"],
        rationale: "Live-confirmed on Logic 12.3: the Marker List toolbar AXMenuButton exposes the exact AXDescription `編集` in Japanese and `편집` in Korean; the bottom AXButton with the same label is deliberately rejected unless its actions advertise AXShowMenu. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Edit%23mti#value"
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
        variants: ["항목 수", "項目数", "Anzahl der Objekte", "Número de ítems", "Nombre d’éléments", "Numero di elementi", "Número de Itens", "项目数", "項目數量"],
        rationale: "Live-measured on Logic 12.3 on 2026-08-17: AXDescription and AXHelp both read `항목 수` in Korean and `項目数` in Japanese, alongside the English `Number of Items`. Until that date this LabelSet deliberately carried no variants because none had been measured; the values it renders were measured in the same pass (`2개의 마커`, `0個のマーカー`) and drove the count parser's separator rule."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Number%20of%20Items#value"
    )

    /// The destructive Marker List Edit-menu command. This must always be whole-string matched.
    static let markerListDeleteMenuItem = LabelSet(
        canonical: "Delete",
        variants: ["削除", "삭제", "Löschen", "Suprimir", "Supprimer", "Elimina", "刪除"],
        rationale: "Live-confirmed on Logic 12.3: Marker List Delete is `削除` in Japanese and `삭제` in Korean. It is used only with exactStrict because the Edit menu also has Delete-Undo-History entries; prefix or containment matching can reach a different destructive command."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#key` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Delete%23key#value"
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
        variants: ["위치로 이동", "位置の移動", "Zu Position", "Ir a la posición", "Aller à la position", "Vai a posizione", "Ir para a posição", "前往位置"],
        rationale: "Used only to dismiss a stale dialog before another verified operation. This covers the reviewed EN/KO/JA dialog titles; broader locale/menu policy remains tracked separately. German read 2026-09-12 by OPENING the dialog on a de-DE Logic and reading its window title (#876), twice, both times `Zu Position` on an AXFloatingWindow. It is not in the navigation-free census — the census opens nothing — which is why the live run that needed it reported `dialog_unidentified_new_window`: the menu leaf fired, the window appeared, and the product could not name it. The AppleScript literal list this LabelSet now renders also carried `Go to Position`, and it is NOT carried here. It had no provenance, `matches(_:mode:.exactStrict)` is case-sensitive so the Swift side never accepted it either, and keeping it would put two members in this set that differ only by case — which `check-probe-product-drift.py` refuses, because a later move to case-folded matching would merge them. So the generated handler is deliberately NARROWER than the literal it replaced by exactly that one string, and the two sides now agree."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FGotoPosition.strings/en/5.title#value"
    )

    static let keyCommandsWindowTitle = LabelSet(
        canonical: "Key Command",
        variants: ["키 명령", "キーコマンド", "Befehlstaste", "Comando de teclado", "Raccourci clavier",
                   "Comando da tastiera", "键盘命令", "按鍵指令"],
        rationale: "Identifies the Key Commands window by title substring. The window Logic opened for"
            + " Option+K was titled `키 명령 할당 – U.S. – 편집됨` when it was read live 2026-09-14; only"
            + " the head is matched because the preset name and the edited marker vary. Apple's row"
            + " is ControllerAssignments `2163.title`, ANCHORED AT ko because the row has no `en` on"
            + " the `strings` side -- English lives in `nibstrings`, the split #895 established --"
            + " so `Key Command` itself is the one member this derivation does not verify. Apple's pt value `Comando de Teclado` is NOT stored: it differs from the es value only by case, and `check-probe-product-drift.py` refuses two members a case-folded match would merge. Every comparison here is case-insensitive, so the es spelling matches a Portuguese reading and nothing is lost -- but the set is one member short of Apple's row for that reason and not by oversight.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FControllerAssignments.strings/ko/2163.title#value"
    )

    static let recordArmKeyCommandName = LabelSet(
        canonical: "Toggle Track Record Enable",
        variants: ["트랙 녹음 활성화 토글", "トラックの録音可能を切り替える",
                   "Spur für die Aufnahme aktivieren ein-/ausschalten",
                   "Activar/desactivar grabación de pista",
                   "Activer/Désactiver l’enregistrement sur piste", "开关轨道录音启用"],
        rationale: "The Key Commands entry `system.setup_arm_key` assigns a chord to. Apple keys it in"
            + " QuickHelp as `KCE_390_ToggTrackRec`; the ko value is what was read live 2026-09-14"
            + " alongside the two sibling commands it must not be confused with. Italian, Portuguese"
            + " and Traditional Chinese leave it in English, so six distinct members cover ten"
            + " languages. Apple's French value carries a trailing space; `.exact` trims surrounding"
            + " whitespace, so it is stored without one.",
        derivedFrom: "logic-canon://quickhelp/QuickHelp/en/KCE_390_ToggTrackRec#Title"
    )

    static let learnByKeyLabelCheckbox = LabelSet(
        canonical: "Learn by Key Label",
        variants: ["키 레이블로 학습", "キーのラベルで登録", "Tastenbeschriftung lernen",
                   "Aprender por etiqueta", "Apprendre par nom de touche",
                   "Apprendi da etichetta tasto", "Aprender por Etiqueta da Tecla", "通过按键标签来学习",
                   "依照按鍵標籤學習"],
        rationale: "The Key Commands checkbox `system.setup_arm_key` toggles before posting its chord,"
            + " distinguished from `키 위치로 학습` and `새로운 할당 학습` when it was read live 2026-09-14."
            + " Apple's row is KeyCommands `300557.title`, ANCHORED AT ko for the same reason as the"
            + " window title: the row has no `en` on the `strings` side.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FKeyCommands.strings/ko/300557.title#value"
    )

    static let cancelButton = LabelSet(
        canonical: "Cancel",
        variants: ["취소", "キャンセル", "Abbrechen", "Cancelar", "Annuler", "Annulla", "取消"],
        rationale: "Dialog dismissal fallback; no success state is inferred from this click. JA live-confirmed (Logic 12.3: `キャンセル`)."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FAddSelToArrange.strings/en/100050.title#value"
    )

    /// #346/#350: the mandatory New Track sheet's only exit ("Create"). The modal
    /// reconciler clicks it to un-wedge Logic, then verifies via track-count
    /// readback — the click itself gates no State-A success. KO live-confirmed
    /// (Logic 12.3: `생성`); JA live-confirmed (Logic 12.3: `作成`).
    ///
    /// Spanish appears TWICE because the cited row is not the one the sheet draws in Spanish. The
    /// row is `Create#und`, and its Spanish is `creación`, a noun. A Spanish Logic 12.3 read on
    /// 2026-09-26 titles the sheet's button `Crear`, which is Apple's plain `Create` row. So in
    /// Spanish the reconciler found no button to press, and `project.new` left the sheet up (#883).
    /// Neither row fits every language: the plain `Create` row reads `Erstellen` in German, but the
    /// German sheet was read the same day as `Erzeugen`. The row stays, because it is what
    /// `derivedFrom` cites and what the offline check pins.
    static let createButton = LabelSet(
        canonical: "Create",
        variants: ["생성", "作成", "Erzeugen", "creación", "Crear", "Créer", "Crea", "Criar", "创建", "製作"],
        rationale: "Mandatory New Track sheet's only exit; reconciler-clicked, then verified by track-count readback. KO live-confirmed (Logic 12.3); JA live-confirmed (Logic 12.3: `作成`)."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#und` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Create%23und#value"
    )

    /// #346/#350: `AXDescription` that identifies the mandatory New Track sheet.
    /// An independent signal the reconciler uses to classify the sheet; on
    /// Japanese Logic 12.3 the Cancel button is enabled. Read-only classifier;
    /// KO live-confirmed (Logic 12.3: `새로운 트랙`); JA live-confirmed (Logic 12.3:
    /// `新規トラック`).
    static let newTrackSheetDescription = LabelSet(
        canonical: "New Track",
        variants: ["새로운 트랙", "新規トラック", "Neue Spur", "Nueva pista", "Nouvelle piste", "Nuova traccia", "Nova Pista", "新轨道", "新增音軌"],
        rationale: "Identifies the mandatory New Track sheet by AXDescription, independently of Cancel state; read-only classifier. KO live-confirmed (Logic 12.3); JA live-confirmed (Logic 12.3: `新規トラック`, Cancel enabled)."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FBounceInPlace.strings/en/12.title#value"
    )

    /// #346/#350/#545: primary destructive button on the track-delete confirm sheets.
    ///
    /// This comment said non-English forms "are absent rather than guessed" while `삭제` and `削除`
    /// sat in the variants list immediately below it — stale safety documentation on a destructive
    /// button, found 2026-09-04 by an outside review. Corrected here rather than by deleting the
    /// variants: they may be load-bearing on a shipped path, and removing a matcher on a
    /// fail-closed delete without measuring first is the more dangerous edit of the two.
    ///
    /// What is true: the English forms are live-measured. Where `삭제` and `削除` came from is not
    /// recorded anywhere, which is exactly what `docs/locale/ui-labels.json`'s `measured` blocks
    /// exist to make visible — both are counted there as variants with no reading behind them.
    /// A locale whose form is genuinely absent still degrades to fail-closed structural matching;
    /// a wrong-title guess or keyboard fallback is never fabricated.
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

    /// The channel configurations a stock plug-in can be inserted as, in the order tried.
    ///
    /// These were four INLINE declarations carrying two languages each -- `Stereo`/`스테레오`,
    /// `Mono`/`모노` and so on. Inline is a shape the projection reads but cannot name, so they
    /// appeared in the ledger as `inline:Stereo` and could never be pointed at from anywhere.
    /// Named and derived on 2026-09-18 (#892); the order is unchanged, which is what the
    /// `leafChoice` single-item rule depends on.
    ///
    /// Measured live the same day on a Korean Logic 12.3: the insert menu's format submenu answers
    /// `스테레오 | 듀얼 모노`, which is the one step of a plug-in insert path that IS localized.
    /// Every category above it -- `Utility`, `Dynamics`, `EQ`, `Audio Units` -- is English on that
    /// same Korean Logic.
    static let pluginFormatStereo = LabelSet(
        canonical: "Stereo",
        variants: ["스테레오", "ステレオ", "Estéreo", "Stéréo", "立体声", "立體聲"],
        rationale: "Plugin format leaf after exact plugin selection. Derived from the row Apple "
            + "keys it under so every language Logic ships is covered.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Stereo#value"
    )

    static let pluginFormatMono = LabelSet(
        canonical: "Mono",
        variants: ["모노", "モノラル", "单声道", "單聲道"],
        rationale: "Plugin format leaf after exact plugin selection. Derived from the row Apple "
            + "keys it under so every language Logic ships is covered.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Mono#value"
    )

    static let pluginFormatMonoToStereo = LabelSet(
        canonical: "Mono->Stereo",
        variants: ["모노->스테레오", "モノラル->ステレオ", "Mono->Estéreo", "Mono->Stéréo", "单声道->立体声", "單聲道->立體聲"],
        rationale: "Plugin format leaf after exact plugin selection. Derived from the row Apple "
            + "keys it under so every language Logic ships is covered.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Mono-%3EStereo#value"
    )

    static let pluginFormatDualMono = LabelSet(
        canonical: "Dual Mono",
        variants: ["듀얼 모노", "デュアルモノ", "Monokanäle", "Mono dual", "双单声道", "雙單聲道"],
        rationale: "Plugin format leaf after exact plugin selection. Derived from the row Apple "
            + "keys it under so every language Logic ships is covered.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Dual%20Mono#value"
    )

    static let pluginFormatLeafPriority: [LabelSet] = [
        pluginFormatStereo,
        pluginFormatMono,
        pluginFormatMonoToStereo,
        pluginFormatDualMono,
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
        variants: ["재생", "再生", "Wiedergabe", "reproducir", "lecture", "riproduci", "reproduzir", "播放"],
        rationale: "Identifies the Play transport control when reading TransportState; read-only."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/play#value"
    )

    static let transportRecordControl = LabelSet(
        canonical: "record",
        variants: ["녹음", "録音", "Aufnahme", "grabar", "enregistrer", "registra", "gravar", "录音", "錄製"],
        rationale: "Identifies the Record transport control; excluded by arm-tokens at the call site; read-only."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMALiveLoopsUI.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/record#value"
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
    /// The Control Bar's count-in checkbox.
    ///
    /// Every variant here is Apple's own, read off `StrTransportBtns|||Count In` in the ten
    /// locales Logic ships — not translated, not typed. Before 2026-09-16 the transport table
    /// carried `("카운트 인", "Count In")` and nothing else, so count-in was unreachable in the
    /// other eight languages.
    /// The plug-in menu's Audio Units category.
    ///
    /// Apple's own, from the `Audio Units` key. Only Chinese translates it, which is exactly why
    /// `titles.contains("Audio Units")` looked safe and was not: the plug-in menu could not be
    /// recognised on a Chinese Logic, and nobody had run one.
    static let pluginMenuAudioUnits = LabelSet(
        canonical: "Audio Units",
        variants: ["音频单元", "音訊單元"],
        rationale: "Derived from Apple's `Audio Units` across the ten locales Logic ships; only zh_CN and zh_TW differ (Logic 12.3 build 6674). Cited in docs/observations/2026-09-16-two-languages-was-the-whole-design.json."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Audio%20Units#value"
    )

    /// The plug-in menu's Utility category.
    ///
    /// NOT derivable: no `.strings` or QuickHelp key holds `Utility`, so this is the other half of
    /// the axis -- a label that exists only as a runtime reading. The Korean was read off a live
    /// menu; the other eight locales are unmeasured and that is visible here rather than hidden in
    /// a `||` chain.
    static let pluginMenuUtility = LabelSet(
        canonical: "Utility",
        variants: ["유틸리티", "ユーティリティ", "UTILIDADES", "UTILITAIRE", "UTILITÁRIO", "实用工具", "實用"],
        rationale: "Absent from every canonical corpus, so measured rather than derived. Korean read off a live plug-in menu; the remaining locales are unmeasured. Carried as a LabelSet so the gap is countable instead of living in a hard-coded `||`."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAMixer.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/UTILITY#value"
    )

    static let transportCountInControl = LabelSet(
        canonical: "Count In",
        variants: ["Einzählen", "Compás de entrada", "Décompte", "Precount", "カウントイン", "카운트 인", "Contagem preparatória", "预备", "預備拍"],
        rationale: "Derived from Apple's own StrTransportBtns|||Count In across all ten locales Logic ships (Logic 12.3 build 6674). Cited in docs/observations/2026-09-16-two-languages-was-the-whole-design.json."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `StrTransportBtns` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrTransportBtns%7C%7C%7CCount%20In#value"
    )

    static let transportMetronomeControl = LabelSet(
        canonical: "metronome",
        variants: ["click", "메트로놈", "클릭", "メトロノームクリック", "メトロノーム", "クリック",
                   "Metronom", "Metrónomo", "Métronome", "Metronomo", "Metrônomo",
                   "节拍器", "節拍器"],
        rationale: "Identifies the Metronome/Click transport control; read-only."
            + " Matching is `containsAny` over a lowercased description and is"
            + " DIACRITIC-SENSITIVE, so the seven members it had reached English, Korean and"
            + " Japanese and nothing else: German renders `Metronom-Klick`, which contains neither"
            + " `metronome` nor `click`, and French `Métronome` differs from `metronome` by an"
            + " accent this comparison respects. `transport.get_state.isMetronomeEnabled` was"
            + " therefore never set in de, es, fr, it, pt or either Chinese -- a plural-looking"
            + " set that reached three languages. Apple's row adds the other seven; the `click`"
            + " members predate it and stay, because the control is named for either word.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Metronome#value"
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

    /// The Japanese form is `再生ヘッドの位置`, WITH the `の`. `再生ヘッド位置`
    /// stood here and was a translation, not a reading: on a ja-JP Logic 12.3
    /// (build 6674) the group's AXDescription is `再生ヘッドの位置`, and this set
    /// is read with `.exactStrict` — whole-string equality — so the old spelling
    /// could never match. The group was therefore unfindable on a Japanese UI,
    /// and with it the bar/beat component sliders every transport read and
    /// `goto_position` resolve through. Measured 2026-09-05 in the arrange
    /// census; the two sliders inside it are `bar` and `beat` in both locales,
    /// which is why only this one line was wrong.
    static let playheadPositionGroupLabel = LabelSet(
        canonical: "playhead position",
        variants: ["재생헤드 위치", "再生ヘッドの位置", "Position der Abspielposition",
                   "Posición del cursor de reproducción", "Position de la tête de lecture",
                   "Posizione testina di riproduzione", "Posição do Cursor de Reprodução",
                   "播放头位置", "播放磁頭位置"],
        rationale: "Identifies Logic 12.3's Playhead Position AXGroup before resolving its bar/beat component sliders."
            + " Read `.exactStrict`, so EVERY bar and beat reading in a language this set does not"
            + " carry was unreachable -- the group is never found, and the transport position and"
            + " the goto_position readback are gone rather than degraded. It carried three"
            + " languages until 2026-09-18, and German was missing with its value already written"
            + " down in this repository: the de-DE arrange-transport census of 2026-09-12 records"
            + " `Position der Abspielposition`, and check-livekit-locale-aliases.py reports a"
            + " measured spelling the policy lacks as a WARNING and exits 0, which is how it"
            + " stayed out. Ten locales now, from Apple's row.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Playhead%20Position#value"
    )

    /// Logic's region AXDescription, as the TEMPLATE Apple ships rather than as four regexes.
    ///
    /// `parseRegionBars` carried one hand-written pattern per language and had four of the ten:
    /// Korean, English, Japanese, German. Each was added the day somebody hit its absence -- the
    /// Japanese one on 2026-09-06, when recognising a region and failing to read its bars returned
    /// `startBar: -1, endBar: -1` for the only region in the campaign project.
    ///
    /// They are not four sentences. They are one row, and the row has ten values:
    ///
    ///     en  Region starts at %@ and ends at %@
    ///     ko  리전은 %@에서 시작하여 %@에서 끝납니다.
    ///     ja  リージョンの開始位置は%@、終了位置は%@です
    ///     de  Region beginnt bei %@ und endet bei %@
    ///
    /// `%@` expands to a number AND a unit -- `128 bars`, `1 마디 `, `2 小節 `, and in German a
    /// unit INFLECTED by the number (`1 Takt ` beside `2 Takte `). So a pattern built from this
    /// template anchors on the literal text around the placeholders and lets the unit fall inside
    /// `.*?`, which is exactly what the four hand-written patterns each worked out separately.
    ///
    /// Verified before the change, against the four sentences this product has actually seen: all
    /// four parse, the three tolerances the English pattern carried (a doubled space, lowercase,
    /// no unit at all) survive, and the `Chord group starts at %@ and ends at %@` sentence -- a
    /// near-twin with its own row -- is refused by all ten patterns.
    static let regionBarsSentence = LabelSet(
        canonical: "Region starts at %@ and ends at %@",
        variants: ["리전은 %@에서 시작하여 %@에서 끝납니다.", "リージョンの開始位置は%@、終了位置は%@です", "Region beginnt bei %@ und endet bei %@", "El pasaje comienza en %@ y termina en %@", "La région commence à %@ et se termine à %@", "Inizio regione: %@; fine regione: %@", "A região começa em %@ e termina em %@", "片段开始于 %@，结束于 %@", "區段起始於 %@，並結束於 %@"],
        rationale: "The sentence Logic renders as a region's AXDescription, in every locale it ships. `AXLocalePolicy.regionBarsPatterns()` turns each into the regex that reads the two bar numbers out of it; the four hand-written patterns this replaces covered four languages. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Region%20starts%20at%20%25%40%20and%20ends%20at%20%25%40#value"
    )

    /// One regex per locale, built from `regionBarsSentence`.
    ///
    /// The transform: split the template on `%@`, escape each literal chunk, let every run of
    /// whitespace inside a chunk match one-or-more, and put `\s*(\d+)` where each placeholder was
    /// with a lazy `.*?` between them for the unit. The whitespace rule is what keeps the English
    /// tolerance the hand-written pattern had; on Korean, Japanese and Chinese it is inert.
    ///
    /// A template without exactly two placeholders yields nothing rather than a half-pattern, and
    /// `Issue778RegionBarsLocaleTests` asserts the count comes back equal to the number of labels
    /// -- silence here would otherwise be a language quietly dropping out.
    static func regionBarsPatterns() -> [String] {
        regionBarsSentence.labels.compactMap { template in
            let parts = template.components(separatedBy: "%@")
            guard parts.count == 3 else { return nil }
            func chunk(_ literal: String) -> String {
                literal.split(whereSeparator: { $0.isWhitespace })
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
            // `(?:[^\\d\\s]+\\s+)?` is the unit BEFORE the number. Logic writes it on both sides of
            // the placeholder -- `Region starts at 1 bar` and `Region starts at bar 1` are both
            // strings this product has had to read -- and the hand-written English pattern carried
            // an optional `bar ` prefix for exactly that. Deriving the pattern without it narrowed
            // English, and CI caught it: `testAccessibilityChannelAXBackedRegionReadAcceptsPlural
            // TracksContentsLabel` reads `at bar 1` and went to (-1, -1).
            //
            // One token, anchored immediately after the literal, so it cannot run off into the
            // rest of the sentence.
            let number = "\\s*(?:[^\\d\\s]+\\s+)?(\\d+)"
            return "(?i)" + chunk(parts[0]) + number + ".*?" + chunk(parts[1]) + number
        }
    }

    // --- Cycle-locator text fields (read-only, `.contains` on AXDescription) ---
    //
    // `setCycle`'s AX path scans the transport bar for two text fields whose descriptions name
    // the cycle and a side. The six literals that stood here -- `cycle`/`사이클`, `start`/`시작`,
    // `end`/`끝` -- were a two-language guess, and one of them is a value of nothing: `끝` is
    // carried by no row in Apple's ten-locale corpus (Apple's `End` is `종료`). Measured on
    // 2026-09-18 by walking all 1334 elements a running Logic 12.3 ko-KR exposes: exactly two
    // name the cycle, the control-bar AXCheckBox `사이클` and the ruler's AXLayoutItem
    // `사이클 리전`, and NEITHER is a text field -- with the LCD in `비트 및 프로젝트` this AX
    // path cannot resolve at all and the osascript fallback carries the operation. So these sets
    // widen a path this repository has never seen resolve; `끝` is kept rather than corrected so
    // that the change can only add.
    //
    // The four English direction words the literals carried -- `in`, `left`, `out`, `right` --
    // are NOT carried forward. They are values of no row Apple ships, the ledger's list of
    // literals answered nowhere in Logic may only shrink, and `in` is two letters that sit
    // inside Spanish `Fin`, Italian `Fine` and Portuguese `Fim`, so carrying it beside ten
    // locales would have made a Latin-locale cycle-END field answer the START test. This
    // narrows the matcher on a path that, as measured above, resolves to nothing.
    //
    // The call site still tests END before START. Neither side's labels are a substring of the
    // other's, so the order does not decide anything today; it is fixed so that a description
    // naming both sides classifies the same way every run rather than by field order.

    static let cycleRangeLabel = LabelSet(
        canonical: "Cycle",
        variants: ["사이클", "サイクル", "Ciclo", "Repetição", "循环", "循環"],
        rationale: "Names the cycle in a transport-bar text field description; read-only locator, ANDed with a side. Derived from Apple's own row, checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Cycle#value"
    )

    static let cycleRangeStart = LabelSet(
        canonical: "Start",
        variants: ["시작", "開始", "Inicio", "Départ", "Inizio", "Iniciar", "开始"],
        rationale: "Names the START side of the cycle range; read-only locator, ANDed with `cycleRangeLabel` and tested only after the end side has been ruled out. The shipped literal also carried `in` and `left`; both are dropped, because neither is a value of any row Apple ships and `in` is a two-letter containment fragment that sits inside Spanish `Fin`, Italian `Fine` and Portuguese `Fim`. Derived from Apple's own row, checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Start#value"
    )

    static let cycleRangeEnd = LabelSet(
        canonical: "End",
        variants: ["종료", "終了", "Ende", "Fin", "Fine", "Fim", "结束", "結束", "끝"],
        rationale: "Names the END side of the cycle range; read-only locator, ANDed with `cycleRangeLabel` and tested BEFORE the start side. `끝` is the shipped Korean literal and is the value of no row in Apple's ten-locale corpus -- kept rather than replaced by `종료` so this change cannot narrow a Korean match somebody may have relied on. The shipped `out` and `right` are dropped for the same reason `in` and `left` are: Apple ships neither as this control's value, and the ledger's list of literals answered nowhere in Logic may only shrink. Derived from Apple's own row, checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/End#value"
    )

    // --- Control-bar slider locators (read-only, verbatim `.exactStrict`) ---

    static let controlBarGroupLabel = LabelSet(
        canonical: "control bar",
        variants: ["컨트롤 막대", "コントロールバー", "Steuerungsleiste", "Barra de controles", "Barre des commandes", "Barra di controllo", "Barra de Controle", "控制条", "控制列"],
        rationale: "Identifies the control-bar AXGroup by description; read-only locator. German read 2026-09-12 off the de-DE navigation-free census (#876): two AXGroups carry `Steuerungsleiste` as their AXDescription, the same count as the en-US `Control Bar` rows."
            + " Extended on 2026-09-16 to every locale Logic ships from the `Control Bar#acc` row. Re-derived on 2026-09-25 (#979) from `StrTabBtnLabel|||Control Bar`, because a Portuguese Logic read live describes the control bar as `Barra de Controles`, the value of that row, where `Control Bar#acc` says `Barra de Controle`. Portuguese carries no member of its own: `Barra de Controles` equals the Spanish member ignoring case, which is how this label is matched, and a second spelling differing only by case is what check-probe-product-drift.py refuses. `Barra de Controle`, the Portuguese value of `Control Bar#acc`, stays a member: it matched before the re-derivation, which moved a citation and was not to narrow what matches, and no reading shows the string cannot appear. Read live in all ten locales, the control bar's description equals this row in each (docs/observations/2026-09-25-979-<locale>-main-window-areas-by-row.json). Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrTabBtnLabel%7C%7C%7CControl%20Bar#value"
    )

    static let barSliderLabel = LabelSet(
        canonical: "bar",
        variants: ["마디", "Takt", "compás", "mesure", "misura", "compasso", "小节", "小節"],
        rationale: "Identifies the bar slider in the control bar; verbatim description match; read-only."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/bar#value"
    )

    static let beatSliderLabel = LabelSet(
        canonical: "beat",
        variants: ["비트", "ビート", "Schlag", "Tiempo", "Temps", "Battito", "Batida",
                   "节拍", "節拍"],
        rationale: "Identifies the beat slider in the control bar; verbatim description match; read-only."
            + " Two languages until 2026-09-18, beside a bar slider the same reader resolves: the"
            + " de-DE census of 2026-09-12 lists `Schlag` and the policy did not carry it. Ten"
            + " locales now, from Apple's row.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Beat#value"
    )

    static let subdivisionSliderLabel = LabelSet(
        canonical: "division",
        variants: ["디비전", "ディビジョン", "Rasterwert", "división", "divisione", "divisão", "个等份", "細分"],
        rationale: "Identifies the subdivision slider in the Playhead Position group; verbatim description match; read-only. Korean read live 2026-09-14 on Logic 12.3 (6674): the group exposes this slider ONLY while the control bar's display mode is `비트` / Beats — in the default `비트 및 프로젝트` it has two children, bar and beat."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/division#value"
    )

    static let tickSliderLabel = LabelSet(
        canonical: "tick",
        variants: ["틱"],
        rationale: "Identifies the tick slider in the Playhead Position group; verbatim description match; read-only. Measured in the same live reading as the subdivision slider, and present under the same condition: display mode `비트` / Beats."
    )

    /// The control bar's display-mode popup, and the mode whose Playhead Position group exposes all
    /// four position components. Read-only locator plus the item title a caller would pick.
    static let displayModePopupLabel = LabelSet(
        canonical: "display mode",
        variants: ["표시 모드", "表示モード", "Anzeigemodus", "Modo de visualización", "Mode d’affichage", "Modalità di visualizzazione", "Modo de visualização", "显示模式", "顯示模式"],
        rationale: "Identifies the control bar's display-mode AXPopUpButton by description. Read live 2026-09-14 on a Korean Logic 12.3; it is the control that decides how many position components the Playhead Position group exposes."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Display%20Mode#value"
    )

    static let beatsDisplayModeItem = LabelSet(
        canonical: "beats",
        variants: ["비트", "拍", "Schläge", "tiempos", "temps", "battiti", "batidas", "个节拍", "節拍"],
        rationale: "The display-mode menu item whose Playhead Position group exposes bar, beat, division and tick. Read live 2026-09-14: selecting it by title moved the group from two named sliders to four, and its own AXValueDescription from `4 마디 1 비트 ` to `4 마디 1 비트 1 디비전 1 틱 `."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/beats#value"
    )

    /// Tempo slider description for `findTempoSlider` (verbatim `.exactStrict`).
    /// Includes `bpm` because that locator explicitly accepts `desc == "bpm"`.
    static let tempoSliderLabel = LabelSet(
        canonical: "tempo",
        variants: ["bpm", "템포", "テンポ"],
        rationale: "Identifies the tempo slider; verbatim (lowercased) description match; read-only. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at the Control Bar tempo slider."
    )

    /// Tempo slider description for the read-only `extractTransportState` slider
    /// loop, which historically matched ONLY `tempo`/`템포` via `.contains`
    /// (NOT `bpm`). Kept distinct from `tempoSliderLabel` to preserve behavior.
    static let tempoSliderContainsLabel = LabelSet(
        canonical: "tempo",
        variants: ["템포", "テンポ", "Ritmo", "Andamento", "速度", "拍速"],
        rationale: "Identifies the tempo slider in TransportState extraction; substring match without bpm; read-only."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Tempo%23mti#value"
    )

    /// #109: arrange Horizontal-Zoom slider (writable AXValue). EN canonical +
    /// KO variant; matched by description substring.
    static let horizontalZoomSlider = LabelSet(
        canonical: "Horizontal Zoom",
        variants: ["가로 확대/축소", "가로 확대", "横方向にズーム"],
        rationale: "Locates the arrange horizontal-zoom AXSlider for verified set_zoom writes; description substring match. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at the arrange horizontal-zoom slider."
    )

    // --- Track-header read-only locators ---

    /// The suffix Logic appends to the arrange window's title. Measured live on 2026-08-11: an
    /// English Logic shows `Untitled 55 - Tracks` and a Korean one `Untitled 55 - 트랙`
    /// (U+D2B8 U+B799). `project.new` uses this suffix as its witness that a project was created, so
    /// an English-only literal made the operation report failure for a project it had just created —
    /// the #516 regression, still live for anyone not running Logic in English.
    static let arrangeWindowTitleSuffix = LabelSet(
        canonical: "Tracks",
        variants: ["트랙", "トラック", "Spuren", "Pistas", "Pistes", "Tracce", "轨道", "音軌"],
        rationale: "Witnesses that an arrange window exists after project.new; read-only classification."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `StrTabBtnLabel` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrTabBtnLabel%7C%7C%7CTracks#value"
    )

    static let trackMuteButton = LabelSet(
        canonical: "Mute",
        variants: ["음소거", "ミュート", "Ton aus", "Silenciar", "Muet", "Muto", "静音", "靜音"],
        rationale: "Identifies the track Mute button by description substring; read-only state extraction. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at the inspector strip's mute button. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Mute%23acc#value"
    )

    static let trackSoloButton = LabelSet(
        canonical: "Solo",
        variants: ["솔로", "ソロ", "Assolo", "独奏", "獨奏"],
        rationale: "Identifies the track Solo button by description substring; read-only state extraction."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Solo%23acc#value"
    )

    static let trackRecordButton = LabelSet(
        canonical: "Record",
        variants: ["Rec", "녹음 활성화", "레코드 활성화", "Aufnahme"],
        rationale: "Identifies the track Record/arm button by description substring; read-only state extraction. German read 2026-09-12 by aligning the en-US and de-DE navigation-free censuses of that day (#876): 1986 aligned pairs with 13 base and 2 target rows unplaced, and this label's string was read off a de-DE element whose AX role its own name requires."
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
        variants: ["오토메이션", "オートメーション", "automatización", "automazione", "automação", "自动化", "自動混音"],
        rationale: "Gates the track-header automation-mode read to the automation control; read-only classifier."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAMixer.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/automation#value"
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
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FAllTracksToWriteMode.strings/en/31.title#value"
    )
    static let automationModeRead = LabelSet(
        canonical: "read",
        variants: ["읽기"],
        rationale: "Classifies the track-header automation mode as Read; read-only classifier."
    )
    static let automationModeOff = LabelSet(
        canonical: "off",
        variants: ["끔", "オフ"],
        rationale: "Classifies an explicit track-header automation Off token; read-only classifier. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at the inspector track outline's automation popup."
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
        variants: ["마커", "マーカー", "Marcador", "Marqueur", "Marcatore", "标记", "標記"],
        rationale: "Last-resort marker-ruler container classifier; read-only keyword scan."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `StrTabBtnLabel` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrTabBtnLabel%7C%7C%7CMarker#value"
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
    /// View > Show Library — COMPOSED, because Apple does not ship this string.
    ///
    /// `Show Library` is in no corpus in any locale, and neither is `\u{B77C}\u{C774}\u{BE0C}\u{B7EC}\u{B9AC} \u{BCF4}\u{AE30}`. Apple ships
    /// `Show %@` and `Hide %@` as TEMPLATES and Logic assembles the item at runtime. Measured on a
    /// running Korean Logic 12.3 on 2026-09-18: the View menu answers
    /// `\u{B77C}\u{C774}\u{BE0C}\u{B7EC}\u{B9AC} \u{AC00}\u{B9AC}\u{AE30}` while the panel is open, and composing the template with the
    /// Library noun reproduces both forms exactly. Regenerate with
    ///
    ///     Scripts/derive_label_variants.py --compose "Show %@" "Library#acc"
    ///
    /// Only the SHOW forms are here. The Hide forms compose just as cleanly and must NOT be in
    /// this set: `clickLibraryMenuItem` presses whatever it matches, so carrying
    /// `\u{B77C}\u{C774}\u{BE0C}\u{B7EC}\u{B9AC} \u{AC00}\u{B9AC}\u{AE30}` would CLOSE a panel the caller asked to open. The bare
    /// `\u{B77C}\u{C774}\u{BE0C}\u{B7EC}\u{B9AC}` is kept as tolerance: it is the panel's own AXDescription, measured live, and a
    /// build that dropped the verb would still be matched.
    ///
    /// No `derivedFrom`: this is not one row's values, it is two rows multiplied. Nothing offline
    /// checks it — `Scripts/check-labelsets-are-derived.py` verifies a row, and a composition has
    /// no row. That gap is #910.
    static let showLibraryMenuItem = LabelSet(
        canonical: "Show Library",
        variants: ["라이브러리 보기", "ライブラリを表示", "Bibliothek einblenden", "Mostrar Biblioteca", "Afficher Bibliothèque", "Mostra libreria", "显示资源库", "顯示「資料庫」", "라이브러리"],
        rationale: "Logic exposes View menu items as localized AX titles without stable "
            + "identifiers. Composed from Apple's `Show %@` template and the Library noun, which is "
            + "why it reaches ten languages while the string itself exists in none."
    )

    static let libraryPanelLabel = LabelSet(
        canonical: "library",
        variants: ["라이브러리", "ライブラリ", "Bibliothek", "Biblioteca", "Bibliothèque", "libreria", "资源库", "資料庫"],
        rationale: "Identifies the Library panel/browser by whole-string description; read-only locator (structural fallback exists)."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Library%23acc#value"
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
        variants: ["인스펙터", "インスペクタ", "Informationen", "Inspecteur", "Inspetor", "检查器", "檢閱器"],
        rationale: "Marks an inspector ancestor so mixer-area detection skips it; read-only classifier."
            + " Extended on 2026-09-16 to every locale Logic ships from the `Inspector#acc` row. Re-derived on 2026-09-25 (#979) from `StrViewBtns|||Inspector`: read live in all ten locales, the Inspector's description equals this row in each, while `Inspector#acc` is lowercase in Italian (`inspector` against the `Inspector` Logic shows). The plain `Inspector` row carries the same ten values; it is not cited because the plain-key namespace was refuted for these areas in the same run, by a German Library described `Bibliothek` where the plain `Library` row says `Mediathek` (docs/observations/2026-09-25-979-<locale>-main-window-areas-by-row.json). Matching ignores case, so no Italian match changes. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrViewBtns%7C%7C%7CInspector#value"
    )

    /// Mixer container id/desc/title exact match (normalized lowercase equality).
    static let mixerNamedElement = LabelSet(
        canonical: "mixer",
        variants: ["믹서", "ミキサー", "Mezclador", "Table de mixage", "混音器"],
        rationale: "Identifies the mixer container by exact normalized name; read-only classifier."
            + " Extended on 2026-09-16 to every locale Logic ships from the `Mixer#acc` row. Re-derived on 2026-09-25 (#979) from `StrTabBtnLabel|||Mixer`: read live in all ten locales, the Mixer's description equals this row in each, while `Mixer#acc` is lowercase in Italian (`mixer` against the `Mixer` Logic shows). The plain `Mixer` and `StrViewBtns|||Mixer` rows carry the same ten values, so the Mixer's own readings cannot choose between the three; the namespace chooses. In the same run every main-window area with a `StrTabBtnLabel` row (Tracks, Control Bar, Library, Mixer) equalled that row in all ten locales, the `#acc` namespace was refuted by spelling in Portuguese (`Barra de Controles`, not `Barra de Controle`), and the plain-key namespace in German (`Bibliothek`, not `Mediathek`) (docs/observations/2026-09-25-979-<locale>-main-window-areas-by-row.json). Matching ignores case, so no Italian match changes. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrTabBtnLabel%7C%7C%7CMixer#value"
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
        variants: ["fader", "볼륨", "ボリューム"],
        rationale: "Classifies a slider as a volume fader; read-only. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at the track area's volume slider."
    )
    static let sliderPanHint = LabelSet(
        canonical: "pan",
        variants: ["panning", "패닝", "밸런스", "パン"],
        rationale: "Classifies a slider as a pan control; read-only. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at the inspector strip's pan slider."
    )

    /// The insert slot's BYPASS toggle -- the child `AXCheckBox` of an occupied slot's `AXGroup`.
    ///
    /// Not the same row as the plug-in editor's bypass (`pluginEditorBypassControl`). Measured
    /// 2026-09-25 on Logic 12.3 (6674) by reading the raw `AXDescription` of both toggles on one
    /// Compressor insert: ko-KR `바이패스` and `바이패스`, de-DE `Umgehen` here and `Bypass` in the
    /// editor, fr-FR `inactif` and `inactif`. The slot's siblings read `geöffnet`/`ouvrir` and
    /// `Liste`/`liste`, which are MAGUI's `open` and `list` -- the rows `pluginSlotOpenControl` and
    /// `pluginSlotListControl` already cite -- and French rules out Logic.framework's `Bypass`,
    /// whose French is `Ignorer`. So this is MAGUI's `bypass`. Those three chose the row; #977 then
    /// read the toggle in all ten locales, and every reading is that row's value.
    static let pluginBypassControl = LabelSet(
        canonical: "bypass",
        variants: ["바이패스", "バイパス", "Umgehen", "desactivar", "inactif", "ignora", "旁通", "略過"],
        rationale: "Locates an insert slot's bypass toggle; read-only locator (structural fallback exists). Read live 2026-09-25 at a Compressor insert slot in all ten locales, each the same row's value (docs/observations/2026-09-25-977-<locale>-insert-slot-bypass-and-open.json, #977). Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAGUI.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/bypass#value"
    )

    /// The plug-in EDITOR window's bypass toggle -- a direct child of the editor's `AXDialog`.
    ///
    /// This label is what tells an open editor from a blocking modal (`isPluginEditorWindow`,
    /// #234/#381) and what `pluginEditorWindows` selects on, and neither has a structural fallback.
    /// Measured 2026-09-25 (see `pluginBypassControl`): de-DE `Bypass`, fr-FR `inactif`, ko-KR
    /// `바이패스`. The header's other toggles read lowercase `vergleichen` (de) and `lien`/`comparer`
    /// (fr); only MAToolKit's lowercase `compare`/`link` rows hold those strings, so the header --
    /// and its bypass -- is MAToolKit's. MAToolKitHighLevel carries a `bypass` row with the same ten
    /// values, so the choice between the two changes no member. German `Bypass` and Portuguese
    /// `bypass` are the canonical under the case-insensitive match and are not repeated. #977 then
    /// read this toggle in all ten locales, and every reading is that row's value.
    static let pluginEditorBypassControl = LabelSet(
        canonical: "bypass",
        variants: ["바이패스", "バイパス", "desactivar", "inactif", "ignora", "旁通", "略過"],
        rationale: "Identifies a plug-in editor window by its bypass toggle, which is what keeps an open editor from reading as a blocking modal. Read live 2026-09-25 in all ten locales, each the same row's value (docs/observations/2026-09-25-977-<locale>-plugin-editor-is-not-a-blocking-modal.json, #977). Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAToolKit.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/bypass#value"
    )

    /// The insert slot's OPEN control, ranked ahead of its list control.
    ///
    /// Measured 2026-09-18 on a running Logic 12.3 ko-KR: the occupied ChromaVerb insert slot
    /// exposes `AXButton` with AXDescription `열기`, and its sibling `목록` carries the
    /// menu-opening action instead. The row named here is MAGUI's lowercase `open`, not either
    /// `Open` row, because its Japanese is `開く` -- the string #795's ja-JP census read at an
    /// insert slot's open button -- while the `Open` rows carry `オープン`.
    static let pluginSlotOpenControl = LabelSet(
        canonical: "open",
        variants: ["열기", "開く", "geöffnet", "abrir", "ouvrir", "apri", "打开", "打開"],
        rationale: "Ranks an insert slot's open control first. Korean read live 2026-09-18 at an occupied insert slot; the other nine are the same row's values. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAGUI.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/open#value"
    )

    /// The insert slot's LIST control, ranked behind the open control.
    ///
    /// Not observed at an insert slot on 2026-09-18: the `목록` buttons that Korean Logic exposes
    /// under each plugin AXGroup all carry the menu-opening action and are filtered out before
    /// ranking, and the only other `목록` button sits under the automation group. The row is
    /// named anyway -- the string the product matches is one of its values -- but this is a
    /// derivation, not a reading.
    static let pluginSlotListControl = LabelSet(
        canonical: "list",
        variants: ["목록", "リスト", "Liste", "lista", "elenco", "列表"],
        rationale: "Ranks an insert slot's list control behind its open control. Derived from Apple's own row; no live reading at an insert slot exists. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAGUI.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/list#value"
    )

    /// The word for a menu, as it appears INSIDE an AX action name.
    ///
    /// Logic localizes its custom action names. Measured 2026-09-18 on Logic 12.3 ko-KR: every
    /// plugin-slot list button and every `오디오 플러그인` insert button carries the action
    /// `Name:Legacy 플러그인으로 플러그인 메뉴 열기`, which is character-for-character the ko value
    /// of `Open plug-in menu with legacy plug-ins` in MAMixer -- 136 buttons carried it. The check
    /// this set replaces looked for `menu` or `메뉴`, which reached five locales rather than two,
    /// because the French, Italian and Portuguese renderings of that sentence happen to contain a
    /// lowercase `menu`. It reached NOTHING in ja, de, es, zh-CN or zh-TW, where a menu-opening
    /// button was not recognized as one and was ranked as an editor control. Every one of the
    /// sentence's ten values contains its own locale's value of this row, so matching here
    /// recognizes the action in every language Logic ships.
    static let menuActionNameFragment = LabelSet(
        canonical: "Menu",
        variants: ["메뉴", "メニュー", "Menü", "Menú", "菜单", "選單"],
        rationale: "Recognizes a menu-opening AX action name. Korean read live 2026-09-18; the other nine are the same row's values, each of which is a substring of that locale's `Open plug-in menu with legacy plug-ins`. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAWorkspace.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Menu#value"
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
        variants: ["보기", "表示", "Ansicht", "Visualización", "Présentation", "Vista", "Visualizar", "显示", "顯示方式"],
        rationale: "Measured live on 2026-09-02 in Compressor: the Controls/editor AXMenuButton identifies itself by AXDescription (View/보기); AXTitle is not a view readback."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#mti` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/View%23mti#value"
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
        variants: ["편집기", "エディタ", "Éditeur", "编辑器", "編輯器"],
        rationale: "Measured live on 2026-09-02 in Compressor's scoped View menu; paired evidence for Controls/컨트롤."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `#acc` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Editor%23acc#value"
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
    /// The bare automation-mode label, which must not be read as a plug-in's name.
    ///
    /// Two members before this: a Korean SENTENCE and the English word. The sentence is redundant
    /// -- `pluginAutomationLabelSubstring` catches it in all ten locales, checked value by value
    /// against Apple's `automation enabled` row -- and the word left Korean uncovered, because
    /// Apple's `Read` row is `Read` in nine locales and `읽기` in exactly one. So a Korean slot
    /// labelled with the bare mode was the single case neither rule caught.
    ///
    /// Measured 2026-09-18 on a running Logic 12.3 ko-KR: the 22 automation groups all carry the
    /// full sentence `읽기, 오토메이션이 활성화됨`, so the substring rule is what fires in practice
    /// and this gap has not been hit. The sentence is kept for that reason and the row is added
    /// for the other one.
    static let pluginAutomationLabelExact = LabelSet(
        canonical: "Read",
        variants: ["읽기", "읽기, 오토메이션이 활성화됨"],
        rationale: "Rejects a bare automation-mode slot label (exact) when extracting a plug-in display name; read-only filter. Derived from Apple's own row, which is `Read` in nine locales and `읽기` in Korean; the Korean sentence is the shape live Logic actually renders and is kept beside it. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAMixer.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Read#value"
    )
    static let pluginAutomationLabelSubstring = LabelSet(
        canonical: "automation",
        variants: ["오토메이션", "オートメーション", "automatización", "automazione", "automação", "自动化", "自動混音"],
        rationale: "Rejects automation-mode slot labels (substring) when extracting a plugin display name; read-only filter."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAMixer.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/automation#value"
    )

    /// Empty audio-plugin insert-slot button classification.
    /// `audio plug-in`, with the hyphen Logic actually renders. `audio plugin`
    /// stood here and is not a substring of what Logic shows, so this set —
    /// read with `containsAny` — could not match an empty slot on any English
    /// Logic. The Korean form was already right; the Japanese one is new and
    /// measured. Whether anything depended on the label is a separate question:
    /// the call site falls through to `isLanguageNeutralEmptyAudioPluginSlot`,
    /// which is substantial enough that the label may never have been
    /// load-bearing, and that was not measured.
    static let audioPluginSlotLabel = LabelSet(
        canonical: "audio plug-in",
        variants: ["audio effect", "오디오 플러그인", "오디오 이펙트", "オーディオプラグイン"],
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
        variants: ["오디오", "オーディオ", "Áudio", "音频", "音訊"],
        rationale: "Classifies an audio track by header aggregate; read-only classifier."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FAdvancedSearch.strings/en/34.title#value"
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
        variants: ["버스", "バス", "总线", "匯流排"],
        rationale: "Classifies a bus track; read-only classifier."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FMAToolKit.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/bus#value"
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
        variants: ["팬", "밸런스", "パン"],
        rationale: "Retired locator for the track-header pan slider; superseded by sliderPanHint. Japanese added 2026-09-07 by aligning the en-US and ja-JP navigation-free censuses of 2026-09-05 (#795): 1005 of 1031 rows align as matching blocks, and this label's element was read at the inspector strip's pan slider."
    )

    /// Track-header rail description (normalized exact match).
    static let trackHeadersDescription = LabelSet(
        canonical: "track headers",
        variants: ["track header", "tracks header", "tracks headers", "트랙 헤더", "Spuren Titel",
                   "トラックヘッダ"],
        rationale: "Identifies the track-header rail by normalized description; read-only classifier (structural detection preferred). German read 2026-09-12 off the de-DE navigation-free census of that day (#876), where it is the AXDescription of the AXGroup this label addresses; the spelling carries its capitals because Logic renders them."
            + " Japanese added 2026-09-18. It was ALREADY MEASURED -- `Scripts/livekit/evidence.py`"
            + " has carried `トラックヘッダ` in its `Tracks header` aliases -- and"
            + " `check-livekit-locale-aliases.py` had been reporting the policy's lack of it as a"
            + " warning that exits 0. A measured spelling the product cannot match is a language"
            + " the product does not work in, so that guard now fails instead, and this was the"
            + " one entry standing between it and doing so."
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
        variants: ["이벤트", "イベント", "Evento", "Évènement", "事件"],
        rationale: "Identifies the Event tab of the List Editors pane; the collector presses it."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control, keyed `StrTabBtnLabel` in Apple's own namespace; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/StrTabBtnLabel%7C%7C%7CEvent#value"
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
    ///
    /// `トラックコンテンツ` is measured, not translated: on a ja-JP Logic 12.3
    /// (build 6674) the arrange canvas is an AXGroup whose AXDescription is
    /// exactly that string, at
    /// `…/AXSplitGroup/AXScrollArea/AXGroup[トラックコンテンツ]`. Without it
    /// `logic_project get_regions` failed with `channels_exhausted` on a
    /// Japanese UI while the identical call succeeded in English — #778.
    static let trackContentExplicit = LabelSet(
        canonical: "트랙 콘텐츠",
        variants: ["track content", "track contents", "tracks content", "tracks contents",
                   "トラックコンテンツ", "Spuren enthält"],
        rationale: "Identifies the arrange Track-Content group by normalized description; read-only classifier. German read 2026-09-12 off the de-DE navigation-free census of that day (#876), where it is the AXDescription of the AXGroup this label addresses; the spelling carries its capitals because Logic renders them."
    )
    /// Fallback for a canvas that is labelled `Contents` rather than
    /// `Tracks contents`. It has NO Japanese form on purpose: the ja-JP census
    /// of this surface shows no AXGroup whose description is `コンテンツ`, and
    /// of the eight rows whose text contains that substring, three are menu
    /// titles, four are help sentences on unrelated controls, and the eighth is
    /// the explicit `トラックコンテンツ` group above. A variant written here
    /// from the explicit form would be a translation of a string Logic does not
    /// show on its own.
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
        variants: ["오디오", "オーディオ", "Áudio", "音频", "音訊"],
        rationale: "Classifies a region as audio content; read-only."
            + " Extended on 2026-09-16 to every locale Logic ships by reading the row Apple keys this control; the strings this label already carried are each one of that row's own values, so nothing measured was dropped and nothing was typed. Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://nibstrings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FAdvancedSearch.strings/en/34.title#value"
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
    /// The variants list grows when a locale is actually observed, not when one is translated.
    /// ko-KR observed 2026-09-04 on Logic 12.3 (6674): four output slots on the open project, each
    /// `AXButton` help `출력 슬롯. 채널 스트립 신호가 전송되는 채널 스트립 출력 대상을 선택하려면 길게
    /// 클릭합니다.` and each described `Stereo Output` — so the description stays English here while
    /// the help does not, and the help is what identifies the slot.
    ///
    /// Until that reading existed the list was empty and this reader returned nil on every strip of
    /// a Korean Logic. `live_291_output_slot_is_read` is what surfaced it: the product published no
    /// output while a second instrument read four off the same screen.
    static let outputSlotHelpKeyword = LabelSet(
        canonical: "output slot",
        variants: ["출력 슬롯"],
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
    /// ko-KR observed 2026-09-04 on Logic 12.3 (6674): one input slot on the open project, help
    /// `입력 슬롯. 채널 스트립 입력 소스를 선택합니다. 오디오 기기…`, described `입력 1`.
    ///
    /// The neighbour hazard survives translation and is one word wide on both sides: the monitoring
    /// button's help reads `입력 모니터링 버튼. 녹음 활성화가 되지 않은…`, which shares its first word
    /// with `입력 슬롯` exactly as `Input Monitoring` shares one with `Input slot`. Matching the full
    /// phrase rather than the word is what keeps the toggle from being published as a source.
    static let inputSlotHelpKeyword = LabelSet(
        canonical: "input slot",
        variants: ["입력 슬롯"],
        rationale: "Detects a channel strip's input slot by its AXHelp string; read-only classifier."
    )

    /// en measured 2026-09-09 on Logic 12.3 (6674), inspector channel strip: an `AXButton` whose
    /// help reads `MIDI Effect slot. Insert a MIDI effect. Click an occupied slot to open the
    /// plug-in.`, described `MIDI plug-in`.
    ///
    /// The full phrase again, and here the neighbour is two words wide rather than one: every
    /// strip that has this one ALSO has `Audio Effect slot`, so a match on `effect slot` would
    /// report an audio track's insert as a MIDI effect slot and make every strip an instrument.
    ///
    /// What this set does NOT establish, and the reason it is not enough on its own: a DRUMMER
    /// track's strip carries the identical slot. Measured the same day on `SoCal`
    /// (`create_drummer`) and `Studio Grand` (`create_instrument`) — same slot, different
    /// instrument-group description, and that description is the plug-in loaded rather than the
    /// kind of track. So this set marks the instrument FAMILY and narrowing it further is a
    /// confident wrong answer on every drummer track.
    static let midiEffectSlotHelpKeyword = LabelSet(
        canonical: "midi effect slot",
        variants: [],
        rationale: "Detects a channel strip's MIDI effect slot by its AXHelp string; read-only classifier."
    )

    /// The inspector's channel strip for the SELECTED track: an `AXLayoutItem` whose help BEGINS
    /// with this phrase. Verbatim from the 2026-09-05 navigation-free censuses:
    ///
    ///     en-US  `Left inspector channel strip. Control the signal of the selected track…`
    ///     ko-KR  `왼쪽 인스펙터 채널 스트립. 믹서를 열지 않고 선택한 트랙의 신호를 제어합니다.`
    ///     ja-JP  `インスペクタの左チャンネルストリップ. 選択したトラックの信号をコントロールします。`
    ///
    /// A PREFIX and not a substring, and the ko-KR census is why that distinction is load-bearing
    /// rather than tidy. The RIGHT strip's help reads
    /// `오른쪽 인스펙터 채널 스트립. … 왼쪽 인스펙터 채널 스트립의 출력 채널 스트립을 표시합니다.` —
    /// it CONTAINS the left strip's phrase in a later sentence, so a substring match selects the
    /// wrong element. Found by review 2026-09-09, after the first version of this set matched by
    /// substring while calling itself a prefix.
    ///
    /// Note the Japanese word order: the modifier follows the noun, so the phrase is not a
    /// translation of the English one and could not have been derived from it.
    static let inspectorChannelStripHelpPrefix = LabelSet(
        canonical: "left inspector channel strip",
        variants: ["왼쪽 인스펙터 채널 스트립", "インスペクタの左チャンネルストリップ"],
        rationale: "Identifies the inspector's channel strip for the selected track; read-only locator. Matched as a PREFIX: the right inspector strip's help contains the left strip's phrase in a later sentence (ko-KR census 2026-09-05), so a substring match selects the wrong element."
    )

    /// en measured 2026-09-09 on an `create_external_midi` track (`Off 1`): its strip has NO
    /// output slot, NO send slot, NO audio effect slot and no EQ, and instead carries
    /// button/slider pairs whose help reads `Assign control. Assign to a MIDI controller, used to
    /// remotely control parameters such as v…`.
    ///
    /// This set is the POSITIVE half of a claim whose other half is an absence, so it is only
    /// usable where the child list was actually read: a strip nobody could read shows no output
    /// slot either.
    static let assignControlHelpKeyword = LabelSet(
        canonical: "assign control",
        variants: [],
        rationale: "Marks an external-MIDI strip's controller-assignment rows; read-only classifier."
    )

    /// Japanese measured 2026-09-06 from the ja-JP arrange-regions census: Logic's help string for
    /// a region reads `リージョンの開始位置は1 bar 、終了位置は2 小節 です, MIDIリージョン. …`.
    ///
    /// Its absence made `get_regions` return an EMPTY enumeration on a Japanese Logic while regions
    /// were plainly there. `AccessibilityChannel+Regions.swift:244` classifies a layout item as a
    /// region iff its help carries one of these, so every Japanese region counted as `nonRegion`:
    /// four separate runs reported `layoutItems: 1, nonRegion: 1, returned_count: 0` where the same
    /// project on an English Logic reported `nonRegion: 0` and one region. The envelope carried no
    /// error and `complete` was true, so it did not look like a failure — it looked like an
    /// arrangement with nothing in it.
    /// The Event List's item-count static text, found by its AXHelp.
    ///
    /// `EventListReadbackCollector` compared `AXHelpers.getHelp($0) == "Number of Items"` -- an
    /// English literal against a localized AXHelp -- so the readback threw `itemCountMissing` in
    /// nine languages. `check-ax-comparisons-use-labelsets.py` could not see it because the help
    /// text arrives as a function PARAMETER rather than a variable assigned from an accessor in
    /// that file; the guard's own docstring names `Region Path` as the kind of finding it exists
    /// for, and it was passing.
    static let eventListItemCountHelp = LabelSet(
        canonical: "Number of Items",
        variants: ["항목 수", "項目数", "Anzahl der Objekte", "Número de ítems",
                   "Nombre d’éléments", "Numero di elementi", "Número de Itens",
                   "项目数", "項目數量"],
        rationale: "Apple's row for the Event List item-count field's AXHelp, read on every MIDI"
            + " readback. Was an English literal compared with `==`.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Number%20of%20Items#value"
    )

    /// The Event List's region-path static text, found by its AXHelp.
    ///
    /// Note the German value carries a trailing colon (`Regionspfad:`) where no other locale does.
    /// That is Apple's own string; matching goes through `.exact`, which trims surrounding
    /// whitespace and compares against every member, so the colon is carried rather than guessed at.
    static let eventListRegionPathHelp = LabelSet(
        canonical: "Region Path",
        variants: ["리전 경로", "リージョンパス", "Regionspfad:", "Ruta del pasaje",
                   "Chemin de la région", "Percorso regione", "Caminho da região",
                   "片段路径", "區段路徑"],
        rationale: "Apple's row for the Event List region-path field's AXHelp. Its absence is what"
            + " `regionPathMissing` reports, and an English-only comparison made that the answer"
            + " in nine languages.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Region%20Path#value"
    )

    /// The Bounce dialog's Normalize setting, by name.
    ///
    /// `Scripts/logic_bounce_ui.py` recognises the bounce settings sheet by looking for its own
    /// controls, and carried `normalize` beside `노멀라이즈` and nothing else -- two languages in a
    /// shipped file no locale guard scanned. Apple's row covers ten.
    /// The plain OK button, as distinct from `saveConfirmationButton`.
    ///
    /// `saveConfirmationButton` bundles `Save` with `OK` because the save-confirmation sheet
    /// offers both. A dialog whose confirm button is OK is a different control, and routing it
    /// through that set would let `Save` confirm a bounce -- a widening nobody asked for. Apple
    /// ships the row; the distinction costs one LabelSet.
    static let okButton = LabelSet(
        canonical: "OK",
        variants: ["확인", "Aceptar", "好"],
        rationale: "Apple's OK row. Seven of the ten locales render `OK` itself, so four distinct"
            + " members cover all ten.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/OK#value"
    )

    static let bounceNormalizeSetting = LabelSet(
        canonical: "Normalize",
        variants: ["노멀라이즈", "ノーマライズ", "Normalisieren", "Normalizar", "Normaliser",
                   "Normalizza", "正常化", "標準化"],
        rationale: "Apple's Normalize row, read for the bounce settings sheet's own marker set."
            + " Portuguese and Spanish share `Normalizar`, so eight distinct members cover ten"
            + " languages.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Normalize#value"
    )

    /// The Bounce dialog's Realtime mode, by name, from the dialog's OWN nib.
    ///
    /// English lives in `nibstrings` (`Base.lproj`) and the other nine locales in `strings` --
    /// the split #895 established -- so this cites the nib side, which is where the English value
    /// Logic actually renders comes from.
    static let bounceRealtimeSetting = LabelSet(
        canonical: "Realtime",
        variants: ["실시간", "リアルタイム", "Echtzeit", "Tiempo real", "Temps réel",
                   "In tempo reale", "Tempo Real", "实时", "即時"],
        rationale: "Apple's own Bounce nib keys this control `afY-gP-VHS.title`, which is the"
            + " strongest provenance available for it. The reference names the `strings`"
            + " side ANCHORED AT ko, because a reference names a locale and `en` is not one"
            + " this row has -- English lives in"
            + " `nibstrings` (Base.lproj) under the same key -- the split #895 established"
            + " -- so `Realtime` itself is the one member this derivation does not verify.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FBounce.strings/ko/afY-gP-VHS.title#value"
    )

    /// The Bounce dialog's Offline mode, from the same nib as Realtime.
    static let bounceOfflineSetting = LabelSet(
        canonical: "Offline",
        variants: ["오프라인", "オフライン", "Sin conexión", "Déconnecté", "Off-line",
                   "离线", "離線"],
        rationale: "Apple's own Bounce nib keys this control `bvc-ZG-Qju.title`. German and"
            + " Italian share the English spelling, so seven distinct members cover ten"
            + " languages. As with Realtime the reference names the `strings` side anchored"
            + " at ko rather than the usual en, because the row has no en, and it"
            + " verifies the nine translated locales; `Offline` itself lives in"
            + " `nibstrings` and is not covered by it.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FBounce.strings/ko/bvc-ZG-Qju.title#value"
    )

    static let regionHelpKeyword = LabelSet(
        canonical: "region",
        variants: ["리전", "リージョン", "Région", "Pasaje", "Regione", "Região", "片段", "區段"],
        rationale: "Detects an arrange region by its AXHelp string; read-only classifier."
            + " It carried three languages until 2026-09-18, and the failure that caused is NOT a"
            + " refusal: `enumerateRegions` classifies a layout item as a region iff this matches"
            + " its help, so in a language it does not cover the call returns `returned_count: 0,"
            + " complete: true` -- an empty project, stated confidently. Matching is"
            + " diacritic-sensitive, so `region` covered German and Italian by accident and missed"
            + " Spanish, French, Portuguese and both Chinese entirely."
            + " Extended to every locale Logic ships from Apple's `Region` row; German and"
            + " English share `Region`, so eight distinct members cover ten languages."
            + " The first version of this change typed a Spanish-looking `Región` in the"
            + " French slot -- a string Apple does not ship anywhere -- and"
            + " check-labelsets-are-derived.py refused it by name, which is the whole"
            + " reason a derived label cites a row instead of listing what looks right."
            + " Checked offline by Scripts/check-labelsets-are-derived.py.",
        derivedFrom: "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Region#value"
    )

    static let showMixerMenuPath = MenuPath(bar: viewMenuBar, item: showMixerMenuItem)
    static let hidePluginWindowsMenuPath = MenuPath(bar: windowMenuBar, item: hideAllPluginWindowsMenuItem)
    static let showStepInputKeyboardMenuPath = MenuPath(
        bar: windowMenuBar,
        item: showStepInputKeyboardMenuItem,
        itemMode: .contains
    )
    static let editUndoMenuPath = MenuPath(bar: editMenuBar, item: undoMenuItemPrefix, itemMode: .prefix)
    // #864 deliberately adds NO Redo label set. A `Redo` prefix would be a second authority claiming
    // the row can be found by its wording, and the measurement says it cannot: with an empty stack
    // Logic writes `Can't Undo`, which the prefix misses, and three Edit-menu titles carry the undo
    // word. `AccessibilityChannel.editStackEntry` finds the row by its SHORTCUT instead, and the
    // menu-bar item above is the only part of that path the wording still decides.

    /// #304: the complete, measured application-menu path. This deliberately does not name the
    /// six disabled region-tempo actions or `Open Smart Tempo Editor`: neither surface was opened
    /// or measured, so callers must refuse them rather than turn a plausible translation into a
    /// menu target.
    static let showTempoListMenuPath = [
        editMenuBar,
        tempoMenuItem,
        showTempoListMenuItem,
    ]

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
        var firstLabelReadFailure: AXHelpers.AXStatusError?
        for candidate in roleCensus.matches {
            switch elementMatchesResult(candidate, labels, mode: mode, runtime: runtime) {
            case .success(true):
                hits.append(candidate)
            case .success(false):
                continue
            case let .failure(error):
                firstLabelReadFailure = firstLabelReadFailure ?? error
            }
        }
        if hits.isEmpty, let firstLabelReadFailure {
            return .failure(firstLabelReadFailure)
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
        var firstReadFailure: AXHelpers.AXStatusError?
        let title: String?
        switch stringAttributeResult(element, kAXTitleAttribute as String, runtime: runtime) {
        case let .success(observed):
            title = observed
        case let .failure(error):
            firstReadFailure = error
            title = nil
        }
        if labels.matches(title, mode: mode) {
            return .success(true)
        }

        let description: String?
        switch stringAttributeResult(element, kAXDescriptionAttribute as String, runtime: runtime) {
        case let .success(observed):
            description = observed
        case let .failure(error):
            firstReadFailure = firstReadFailure ?? error
            description = nil
        }
        if labels.matches(description, mode: mode) {
            return .success(true)
        }
        if let firstReadFailure {
            return .failure(firstReadFailure)
        }
        return .success(false)
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
        keyCommandsWindowTitle,
        recordArmKeyCommandName,
        learnByKeyLabelCheckbox,
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
        projectChooserWindowTitle,
        projectChooserCommitButton,
        projectChooserEmptyProjectLabel,
        applicationMenuBarItem,
        controlSurfacesMenuItem,
        controlSurfaceSetupMenuItem,
        controlSurfaceSettingsMenuItem,
        controlSurfaceSetupWindowTitle,
        controlSurfaceNewMenuButton,
        controlSurfaceInstallMenuItem,
        controlSurfaceInstallWindowTitle,
        controlSurfaceAddButton,
        controlSurfaceOutputPortLabel,
        controlSurfaceInputPortLabel,
        controlSurfaceModelLabel,
        exportMenuItem,
        allTracksAsAudioFilesMenuItem,
        oneFilePerTrackPopupValue,
        stemExportCommitButton,
        stemExportDismissButton,
        stemExportProgressWindowTitle,
        editMenuBar,
        navigateMenuBar,
        trackMenuBar,
        sortTracksByMenuItem,
        sortTracksByMIDIChannelMenuItem,
        sortTracksByAudioChannelMenuItem,
        sortTracksByOutputChannelMenuItem,
        sortTracksByInstrumentNameMenuItem,
        sortTracksByTrackNameMenuItem,
        sortTracksByUsedMenuItem,
        sortTracksByCreationDateMenuItem,
        saveAsMenuItem,
        savePanelWindowTitle,
        savePanelPackageRadio,
        savePanelFolderRadio,
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
        newSoftwareInstrumentTrackMenuItem,
        newAudioTrackMenuItem,
        newSessionPlayerTrackMenuItem,
        newExternalMIDITrackMenuItem,
        renameTrackMenuItem,
        renameTrackMenuItem,
        deleteTrackMenuItem,
        markerEditToggle,
        markerListEditMenuButton,
        markerListNumberOfItemsLabel,
        markerListDeleteMenuItem,
        undoMenuItemPrefix,
        undoPluginInsertMenuItem,
        tempoMenuItem,
        showTempoListMenuItem,
        tempoListNumberOfItemsLabel,
        goToPositionDialogTitle,
        cancelButton,
        createButton,
        newTrackSheetDescription,
        deleteTracksPrimaryButton,
        saveConfirmationButton,
        transportCountInControl,
        pluginFormatStereo,
        pluginFormatMono,
        pluginFormatMonoToStereo,
        pluginFormatDualMono,
        pluginMenuAudioUnits,
        pluginMenuUtility,
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
        subdivisionSliderLabel,
        tickSliderLabel,
        displayModePopupLabel,
        beatsDisplayModeItem,
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
        showLibraryMenuItem,
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
        pluginEditorBypassControl,
        pluginSlotOpenControl,
        pluginSlotListControl,
        menuActionNameFragment,
        cycleRangeLabel,
        cycleRangeStart,
        cycleRangeEnd,
        regionBarsSentence,
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
        midiImportPanelTitle,
        midiImportCommitButton,
        midiImportDeclineTempoButton,
        midiImportTempoAlertText,
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
        midiEffectSlotHelpKeyword,
        inspectorChannelStripHelpPrefix,
        assignControlHelpKeyword,
        okButton,
        bounceNormalizeSetting,
        bounceOfflineSetting,
        bounceRealtimeSetting,
        eventListItemCountHelp,
        eventListRegionPathHelp,
        regionHelpKeyword,
    ]
}
