import ApplicationServices
import Foundation

/// Process-local AX observation. Never encoded, imported, or reconstructed from a label/index.
enum AXMixerStripBinding {
    struct Binding: @unchecked Sendable {
        let window: AXUIElement
        let mixer: AXUIElement
        let strip: AXUIElement
        let document: String

        var projectPath: String? { URL(string: document)?.path }

        func matches(_ other: Binding) -> Bool {
            CFEqual(window, other.window) && CFEqual(mixer, other.mixer) && CFEqual(strip, other.strip)
                && document.utf8.elementsEqual(other.document.utf8)
        }

        /// Re-read owner and complete current membership, not the cached ordinal or strip name.
        func currentIndex(runtime: AXLogicProElements.Runtime) -> Int? {
            guard !Task.isCancelled,
                  case .found(let currentWindow) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(window, currentWindow),
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(
                    app, kAXWindowsAttribute as String, runtime: runtime.ax),
                  windows.contains(where: { CFEqual($0, window) }),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  document.utf8.elementsEqual(currentDocument.utf8),
                  case .found(let currentMixer) = AXLogicProElements.mixerAreaLookup(in: window, runtime: runtime),
                  CFEqual(mixer, currentMixer),
                  let enumeration = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: runtime.ax)
            else { return nil }
            let matching = enumeration.strips.indices.filter { CFEqual(enumeration.strips[$0], strip) }
            return matching.count == 1 ? matching[0] : nil
        }
    }

    @TaskLocal static var current: Binding?
}

extension AXLogicProElements {
    // MARK: - Mixer

    /// What looking for the Mixer found (#982). A children read that failed at or inside a
    /// Mixer-named container outside the Inspector may have hidden the Mixer's strips, so when no
    /// readable Mixer stands beside it the answer is `childrenUnread`, not `notFound`.
    enum MixerAreaLookup {
        case found(AXUIElement)
        case childrenUnread
        case notFound

        var mixer: AXUIElement? {
            if case let .found(mixer) = self { return mixer }
            return nil
        }

        var childrenUnread: Bool {
            if case .childrenUnread = self { return true }
            return false
        }
    }

    /// Find the mixer area. Nil folds `childrenUnread` into `notFound`; a caller that reports why
    /// the Mixer is missing asks `mixerAreaLookup` instead.
    static func getMixerArea(runtime: Runtime = .production) -> AXUIElement? {
        mixerAreaLookup(runtime: runtime).mixer
    }

    static func mixerAreaLookup(runtime: Runtime = .production) -> MixerAreaLookup {
        guard let window = mainWindow(runtime: runtime) else { return .notFound }
        return mixerAreaLookup(in: window, runtime: runtime)
    }

    static func mixerAreaLookup(in window: AXUIElement, runtime: Runtime) -> MixerAreaLookup {

        // Legacy/test-path lookup. Older Logic builds and existing fake AX
        // trees expose the mixer with AXIdentifier="Mixer".
        if let mixer = AXHelpers.findDescendant(
            of: window, role: kAXGroupRole, identifier: "Mixer", runtime: runtime.ax
        ) {
            return .found(mixer)
        }
        if let mixer = AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Mixer", runtime: runtime.ax
        ) {
            return .found(mixer)
        }

        // #234: Logic Pro 12.2 exposes the visible bottom Mixer as:
        //   AXGroup(desc:"믹서") -> AXLayoutArea(desc:"믹서") -> AXLayoutItem strips
        // with no AXIdentifier. Logic Pro 12.3 wraps that layout area with an
        // outer AXGroup(desc:"Mixer") and a sibling toolbar AXGroup(desc:"Mixer").
        // Do not fall back to the Inspector's small two-strip "믹서" area; that
        // would make a full mixer read silently return only selected-track +
        // output strips.
        let scan = mixerAreaCandidates(in: window, runtime: runtime.ax)
        let best = scan.candidates
            .sorted { lhs, rhs in
                if lhs.stripCount != rhs.stripCount { return lhs.stripCount > rhs.stripCount }
                return lhs.totalChildCount > rhs.totalChildCount
            }
            .first?
            .element
        if let best { return .found(best) }
        return scan.sawUnreadMixerContainer ? .childrenUnread : .notFound
    }

    /// #107: the per-track volume fader inside the track HEADER (an AXSlider
    /// whose value-indicator reads "Volume"). Same channel parameter as the
    /// mixer-strip fader, but identity-safe — it belongs to exactly track
    /// `index` — and always present without the Mixer being visible. Callers
    /// drive it with AXIncrement/AXDecrement detents, then one-raw AXValue writes
    /// (#973: measured on Logic 12.3.1, a write moves it one raw unit toward it).
    static func findTrackHeaderVolumeFader(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return nil }
        return findVolumeFader(in: header, runtime: runtime.ax)
    }

    /// #107: the per-track pan slider inside the track HEADER. Its own
    /// description is empty; the "Pan"/"팬" label lives on its
    /// `AXValueIndicator` child. Falls back to the non-volume slider.
    static func findTrackHeaderPanControl(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return nil }
        return findPanControlInHeader(header, runtime: runtime.ax)
    }

    /// Every slider on a header whose children describe it as a pan control, in tree order.
    ///
    /// Split out so a probe can call the SAME predicate the product runs rather than a copy of it.
    /// The copy existed for one commit and is exactly what #628 is a census of: a measurement that
    /// can drift from the code and then disagree with it for a reason unrelated to the tree.
    static func headerPanSliderCandidates(
        among sliders: [AXUIElement],
        runtime: AXHelpers.Runtime = .production
    ) -> [AXUIElement] {
        // This used to run its own predicate — `headerPanHint` against the CHILDREN's
        // `AXDescription` — and `--probe-selection-census` measured it at zero survivors of two
        // sliders on every header, so `findPanControlInHeader` reached its elimination fallback
        // every time.
        //
        // Measured 2026-08-24, Logic 12.x (ko), read off the live tree: the header pan slider has
        // no `AXDescription`, and no `AXIdentifier` — that attribute is absent from the element
        // entirely. What it carries is `AXHelp` = "패닝 노브 및 밸런스 노브".
        //
        // The product already had a predicate that reads that. `sliderText` searches
        // identifier + description + title + HELP, and `sliderPanHint` carries `패닝` and `밸런스`;
        // it is what `findPanControl` uses for mixer strips, where the same census measured one
        // survivor of two. So this was not a missing capability, it was a second, weaker copy of an
        // existing one — used on headers only, and never matching. Deleting the copy is the fix.
        //
        // Checked that it still separates the pair rather than assuming it: the volume fader's
        // searchable text ("볼륨", "볼륨 페이더. …") carries none of `pan` / `panning` / `패닝` /
        // `밸런스`. `sliderText` also excludes send and zoom sliders, which the deleted copy did
        // not — strictly narrower, not wider.
        sliders.filter { slider in
            let candidate = AXResolvableCandidate.make(
                from: slider, ancestors: ["AXLayoutItem"], runtime: runtime)
            return resolve(headerPanSelector, in: [candidate], locale: "any") == .exact(index: 0)
        }
    }

    /// The atlas selector for a track-header pan slider — the FIRST production adoption of
    /// `SelectorAtlas`.
    ///
    /// The atlas had every piece and zero callers, because nothing turned an `AXUIElement` into a
    /// `ResolvableCandidate` and because the scoring could not clear an ordinary threshold without
    /// an `AXIdentifier` Logic does not expose here. Both are fixed, so the rules this site runs are
    /// now the rules the atlas expresses rather than a predicate written beside it.
    ///
    /// The evidence is the measured evidence: `AXHelp` carrying one of `sliderPanHint`'s labels,
    /// and the `0...127` range that separates pan from the volume fader's `0...233` and does not
    /// depend on locale. `failClosed` is the policy — two candidates are a refusal, which is what
    /// `findPanControlInHeader` already does and what ADR-007 requires of a mutating path.
    ///
    /// `locale: "any"` because the alias set is not keyed by locale here: `attributeContainsAny`
    /// carries every measured label at once, which is how `AXLocalePolicy` has always matched.
    static let headerPanSelector = SemanticSelector(
        id: .trackHeaderPanControl,
        requiredRole: kAXSliderRole as String,
        allowedSubroles: [],
        titleAliases: [:],
        ancestorConstraints: [AncestorConstraint(role: "AXLayoutItem")],
        attributePredicates: [
            .attributes([kAXHelpAttribute as String,
                         kAXDescriptionAttribute as String,
                         kAXRoleDescriptionAttribute as String],
                        anyOf: AXLocalePolicy.sliderPanHint.labels, mode: .contains),
            .valueSignature("0...127"),
        ],
        geometryHint: nil,
        minimumConfidence: 0.6,
        ambiguityPolicy: .failClosed
    )

    /// `AXMaxValue` of a track-header pan slider, measured at 127 against the volume fader's 233.
    ///
    /// A value-range signature, so unlike the help text it does not depend on locale. Used only to
    /// separate candidates when the hint leaves more than one — never on its own, because a range
    /// is a weaker claim about identity than a name.
    static let headerPanSliderMaxValue: Double = 127

    /// Header-level pan-slider selection (split out for deterministic testing).
    ///
    /// Only the Korean help string is measured. On a locale whose `AXHelp` carries none of the
    /// hint's variants the predicate yields nothing, and this falls through to elimination exactly
    /// as it did before — so an unmeasured locale is no worse off, and never silently better.
    static func findPanControlInHeader(_ header: AXUIElement, runtime: AXHelpers.Runtime = .production) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(of: header, role: kAXSliderRole, maxDepth: 4, runtime: runtime)
        let candidates = headerPanSliderCandidates(among: sliders, runtime: runtime)

        if candidates.count == 1 { return candidates[0] }

        if candidates.count > 1 {
            // Narrow by the value-range signature before giving up — it does not depend on locale.
            let ranged = candidates.filter { slider in
                let maxValue: Double? = AXHelpers.getAttribute(
                    slider, kAXMaxValueAttribute as String, runtime: runtime)
                return maxValue.map { abs($0 - headerPanSliderMaxValue) < 0.5 } ?? false
            }
            if ranged.count == 1 { return ranged[0] }
            // Refusing, not choosing. Returning the first in tree order is what the census on #628
            // exists to find, and here there is nothing left to distinguish them by.
            Log.info("findPanControlInHeader: \(candidates.count) sliders carry a pan identity and "
                + "\(ranged.count) carry the measured range; refusing rather than picking one",
                subsystem: "ax")
            return nil
        }

        // No slider named itself. Elimination is the last resort, and it is only correct while
        // there are exactly two sliders and the other one IS named — an asymmetry the code relied
        // on without stating. Saying so means a tree where it stops holding leaves a trace.
        //
        // Volume identity is judged over `sliders` itself, not by `findVolumeFader`, which walks
        // the header again. A second walk is a second inventory: a subtree that read once and then
        // read empty left that walk one volume slider to call unique, and elimination handed back
        // the OTHER volume slider as pan.
        let volumes = volumeFaderCandidates(among: sliders, runtime: runtime)
        guard sliders.count == 2, volumes.count == 1 else {
            let counts = "\(sliders.count) sliders, \(volumes.count) volume"
            Log.info("findPanControlInHeader: elimination needs two sliders and one volume identity (\(counts)); refusing",
                     subsystem: "ax")
            return nil
        }
        let volume = volumes[0]
        let eliminated = sliders.first { !CFEqual($0, volume) }
        if eliminated != nil {
            Log.info("findPanControlInHeader: no slider among \(sliders.count) carries a pan "
                + "identity; selecting by elimination against the volume fader", subsystem: "ax")
        }
        return eliminated
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime),
              let strips = mixerChannelStrips(in: mixer, runtime: runtime.ax) else { return nil }
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        return findVolumeFader(in: strip, runtime: runtime.ax)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime),
              let strips = mixerChannelStrips(in: mixer, runtime: runtime.ax) else { return nil }
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        return findPanControl(in: strip, runtime: runtime.ax)
    }

    private struct MixerAreaCandidate {
        let element: AXUIElement
        let stripCount: Int
        let totalChildCount: Int
    }

    private static func mixerAreaCandidates(
        in root: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> (candidates: [MixerAreaCandidate], sawUnreadMixerContainer: Bool) {
        var candidates: [MixerAreaCandidate] = []
        var sawUnreadMixerContainer = false
        collectMixerAreaCandidates(
            root,
            runtime: runtime,
            depth: 0,
            ancestorIsInspector: false,
            ancestorIsMixer: false,
            into: &candidates,
            sawUnreadMixerContainer: &sawUnreadMixerContainer
        )
        return (candidates, sawUnreadMixerContainer)
    }

    private static func collectMixerAreaCandidates(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime,
        depth: Int,
        ancestorIsInspector: Bool,
        ancestorIsMixer: Bool,
        into candidates: inout [MixerAreaCandidate],
        sawUnreadMixerContainer: inout Bool
    ) {
        guard depth <= 12 else { return }

        let text = elementSearchText(element, runtime: runtime)
        let isInspector = ancestorIsInspector
            || AXLocalePolicy.mixerInspectorContext.containsAny(in: text)
        let isMixerContainer = !isInspector
            && isMixerNamedElement(element, runtime: runtime)
            && isMixerContainerRole(AXHelpers.getRole(element, runtime: runtime))
        // Read once, with its status (#982). `getChildren` answers a failed read with [], which
        // made a Mixer whose children did not read look like a container with no strips. A failed
        // read inside a Mixer-named container outside the Inspector (12.3 puts an unnamed group
        // between its outer group and the layout area) hides strips that may be there.
        guard let children = childrenIfRead(element, runtime: runtime) else {
            if !isInspector, ancestorIsMixer || isMixerContainer {
                sawUnreadMixerContainer = true
            }
            return
        }

        if isMixerContainer {
            let strips = channelStripLayoutItems(children, runtime: runtime)
            if !strips.isEmpty {
                candidates.append(MixerAreaCandidate(
                    element: element,
                    stripCount: strips.count,
                    totalChildCount: children.count
                ))
            }
        }

        for child in children {
            collectMixerAreaCandidates(
                child,
                runtime: runtime,
                depth: depth + 1,
                ancestorIsInspector: isInspector,
                ancestorIsMixer: !isInspector && (ancestorIsMixer || isMixerContainer),
                into: &candidates,
                sawUnreadMixerContainer: &sawUnreadMixerContainer
            )
        }
    }

    private static func isMixerContainerRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == (kAXGroupRole as String)
            || role == (kAXScrollAreaRole as String)
            || role == "AXLayoutArea"
    }

    private static func isMixerNamedElement(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let candidates = [
            AXHelpers.getIdentifier(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
            AXHelpers.getTitle(element, runtime: runtime)
        ]
        // `containsNormalized`, not a lowercased reading against `.labels`: the derived members keep
        // Apple's capitals, so `table de mixage` never equalled `Table de mixage` and the Mixer was
        // not found at all on a French or Spanish Logic (#977).
        return candidates.contains { AXLocalePolicy.mixerNamedElement.containsNormalized($0) }
    }

    private static func channelStripLayoutItems(
        _ children: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement] {
        children.filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXLayoutItemRole as String)
        }
    }

    /// The Mixer's strips, or nil when its children did not read (#982). Nil is not a Mixer with
    /// no strips: a reader reports it as unknown and a mutating caller refuses.
    static func mixerChannelStrips(
        in mixer: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [AXUIElement]? {
        stripEnumeration(in: mixer, runtime: runtime)?.strips
    }

    /// The strips, but only when the enumeration read EVERY child (#290).
    ///
    /// `stripEnumeration` has always counted the children whose role would not read, and every
    /// caller threw that count away. The comment on it says what the count is for: a dropped child
    /// moves every later strip down one, and callers address strips by ORDINAL — so a request for
    /// track 0 acts on physical strip 1, and no readback catches it, because the readback reads the
    /// same shifted list.
    ///
    /// This is ADR-007's rule applied to the one place it is already measurable: resolve exactly, or
    /// refuse. A caller that indexes the result of this function is indexing a list that was read
    /// whole.
    static func mixerChannelStripsIfCompletelyRead(
        in mixer: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> (strips: [AXUIElement], unreadableChildren: Int)? {
        guard let enumeration = stripEnumeration(in: mixer, runtime: runtime),
              enumeration.unreadableChildren == 0 else { return nil }
        return enumeration
    }

    /// The strips, plus whether any child's role could not be read.
    ///
    /// A child whose role is unreadable is dropped by the filter, and every later strip then moves
    /// down one. Callers address strips by ORDINAL, so a request for track 0 would act on physical
    /// strip 1 — a wrong-target write that no downstream readback can catch, because the readback
    /// reads the same shifted list. The count is returned so a mutating caller can refuse instead of
    /// addressing a list it cannot trust. A read-only caller may still use the strips.
    ///
    /// Nil when the Mixer's own children did not read (#982). `getChildren` answers that failure
    /// with [], which this function used to enumerate as a Mixer with no strips and zero unreadable
    /// children: a complete read of nothing.
    static func stripEnumeration(
        in mixer: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> (strips: [AXUIElement], unreadableChildren: Int)? {
        childrenIfRead(mixer, runtime: runtime).map { stripEnumeration(children: $0, runtime: runtime) }
    }

    /// An element's children, or nil when they did not read (#982). -25205 and -25212 are answers
    /// that the element has no children, so they read as []; any other failure is unknown, not
    /// empty.
    static func childrenIfRead(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case let .success(children): return children
        case let .failure(error) where error.isDefinitiveAbsence: return []
        case .failure: return nil
        }
    }

    /// The same enumeration over children the caller already read, so a caller that reads them with
    /// `childrenResult` can tell a failed read from a Mixer with no strips (#972).
    static func stripEnumeration(
        children: [AXUIElement],
        runtime: AXHelpers.Runtime = .production
    ) -> (strips: [AXUIElement], unreadableChildren: Int) {
        var unreadable = 0
        var layoutItems: [AXUIElement] = []
        for child in children {
            guard let role = AXHelpers.getRole(child, runtime: runtime) else {
                unreadable += 1
                continue
            }
            if role == (kAXLayoutItemRole as String) { layoutItems.append(child) }
        }
        return layoutItems.isEmpty
            ? (children, unreadable)
            : (layoutItems, unreadable)
    }

    /// What a channel strip's output slot says it is routed to (#291).
    ///
    /// Returns the slot button's `AXDescription` — measured on Logic Pro 12.3 as "Stereo Output" for
    /// a track going to the main output. `nil` means no output slot was identified, which is the
    /// honest answer on a Logic whose help strings this project has not measured, or on a strip whose
    /// buttons did not read. An absent output is not the same as a track routed nowhere, and callers
    /// are expected to treat it as unknown.
    ///
    /// Sends deliberately have no counterpart here. The send slot is an `AXButton` described only as
    /// "send button", and an empty one exposes no `AXValue`, `AXValueDescription` or `AXTitle` — so
    /// there is nothing to read a destination from, and this file does not pretend otherwise.
    static func outputSlotDestination(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> String? {
        slotDescription(in: strip, matching: AXLocalePolicy.outputSlotHelpKeyword, runtime: runtime)
    }

    /// The output slot's button itself (#291 R2): the element `logic_mixer set_output_verified`
    /// presses to open the strip's output popup.
    ///
    /// Found by the same walk and help match `outputSlotDestination` reads through, so the button
    /// that is pressed is the button whose description the before and after reads come from. A
    /// second search for "the output button" would be a second place to pick a different one.
    static func outputSlotButton(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        slotButton(in: strip, matching: AXLocalePolicy.outputSlotHelpKeyword, runtime: runtime)
    }

    /// The first button under the strip whose help matches, or nil.
    private static func slotButton(
        in strip: AXUIElement,
        matching keyword: AXLocalePolicy.LabelSet,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.findAllDescendants(
            of: strip, role: kAXButtonRole, maxDepth: 4, runtime: runtime
        ).first { button in
            keyword.containsAny(in: (AXHelpers.getHelp(button, runtime: runtime) ?? "").lowercased())
        }
    }

    /// The description of the first slot button whose help matches, or nil.
    ///
    /// Shared by the input and output readers so the two cannot drift apart — a second copy of this
    /// walk is a second place for the "found it but it named nothing" case to be decided differently.
    private static func slotDescription(
        in strip: AXUIElement,
        matching keyword: AXLocalePolicy.LabelSet,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard let button = slotButton(in: strip, matching: keyword, runtime: runtime) else {
            return nil
        }
        guard let description = AXHelpers.getDescription(button, runtime: runtime),
              !description.isEmpty else {
            // The slot was found and did not name anything. That is a gap, not an empty route,
            // so it reads the same as not finding the slot at all.
            return nil
        }
        return description
    }

    /// What a channel strip's input slot says its source is (#291).
    ///
    /// Same shape as `outputSlotDestination`, and the same refusals: `nil` when no input slot was
    /// identified, when the slot named nothing, or on a locale whose help string this project has
    /// not measured. A software-instrument strip has no input slot at all, so `nil` there is the
    /// truth — but the reader cannot tell that case from the others, and callers are expected to
    /// treat an absent input as unknown rather than as "no input".
    ///
    /// The keyword is the full phrase. Measured on the same strip: an `AXButton` whose help begins
    /// "Input Monitoring button. Hear incoming signal…" sits beside the input slot, and a match on
    /// the word "input" alone would publish that toggle as a source.
    static func inputSlotSource(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> String? {
        slotDescription(in: strip, matching: AXLocalePolicy.inputSlotHelpKeyword, runtime: runtime)
    }

    /// The three answers `inputSlotSource` folds into `nil`, kept apart (#291 R2).
    enum InputSlotReading: Equatable, Sendable {
        /// The sole recognised slot's description, with no unread possible competitor.
        case source(String)
        /// Every element in the walk read, no button's help named the input slot, and no button
        /// whose help named none of the input, output and send slots is described as a bus; the
        /// bounded walk also established that it omitted no descendants: a
        /// software instrument strip, or one whose unrecognised buttons all name something else.
        case noSlot
        /// A children, role or help read in the walk failed; the slot was found and named nothing;
        /// the description of a button whose help named no known slot failed to read; or such a
        /// button is described as a bus — possibly another input slot whose help wording this
        /// project's LabelSet does not know; or matching slots repeat or descendants exceed the bound.
        case unreadable
    }

    /// `inputSlotSource` with "no input slot" told apart from "did not read", for a caller whose
    /// safety depends on the difference: `set_output_verified` treats a strip with no input slot
    /// as one no bus can feed, which it may do only when that absence was read.
    ///
    /// The walk and depth of `slotButton`, taken through `preOrderDescendants` and
    /// `slotDecidingString`, so -25205 and -25212 are answers and any other failed read makes the
    /// reading `.unreadable` instead of passing the element over.
    ///
    /// `.noSlot` is an absence that was established, not a keyword that failed to match (#1062
    /// review R2-02): every `AXButton` whose help (nil counts) names none of the input, output and
    /// send slots has its `AXDescription` read, and if any is described as a bus
    /// (`RoutingGraphPublication.classifyOutputLabel` gives `.bus`) the reading is `.unreadable`,
    /// because an input slot whose help wording is not in the LabelSet would read exactly so. A
    /// description that answers -25205/-25212 is no description; any other failure is
    /// `.unreadable`. Measured on Logic 12.3 ko, 2026-09-29, three strips (Inspector, "오디오 1",
    /// "Aux 1"): the input slot's help is identical on the audio and aux strip and its description
    /// is the source ("버스 2", "버스 1"); the other buttons are described 음소거, 솔로, 녹음, 모니터링,
    /// 피크 레벨 측정기, 목록, Stereo Output, 보내기 버튼, 오디오 플러그인, 채널 모드, EQ,
    /// 게인 축소 측정기, 설정, 라이브러리 표시기 — none a bus label.
    static func inputSlotReading(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> InputSlotReading {
        guard let walk = preOrderDescendants(of: strip, maxDepth: 4, runtime: runtime) else {
            return .unreadable
        }
        var unidentifiedButtonNamesBus = false
        var source: String?
        for visit in walk {
            // A truncated subtree cannot establish absence or uniqueness. Only this input
            // reading needs the extra boundary check; the output/send readers are unchanged.
            if visit.depth == 4 {
                guard let children = childrenIfRead(visit.element, runtime: runtime), children.isEmpty else {
                    return .unreadable
                }
            }
            guard case let .success(role) = slotDecidingString(
                visit.element, kAXRoleAttribute as String, runtime: runtime
            ) else { return .unreadable }
            guard role == (kAXButtonRole as String) else { continue }
            guard case let .success(help) = slotDecidingString(
                visit.element, kAXHelpAttribute as String, runtime: runtime
            ) else { return .unreadable }
            let loweredHelp = (help ?? "").lowercased()
            guard AXLocalePolicy.inputSlotHelpKeyword.containsAny(in: loweredHelp) else {
                guard !AXLocalePolicy.outputSlotHelpKeyword.containsAny(in: loweredHelp),
                      !AXLocalePolicy.sendSlotHelpKeyword.containsAny(in: loweredHelp) else { continue }
                guard case let .success(description) = slotDecidingString(
                    visit.element, kAXDescriptionAttribute as String, runtime: runtime
                ) else { return .unreadable }
                if let description,
                   RoutingGraphPublication.classifyOutputLabel(description).0 == .bus {
                    unidentifiedButtonNamesBus = true
                }
                continue
            }
            guard source == nil,
                  case let .success(description) = slotDecidingString(
                    visit.element, kAXDescriptionAttribute as String, runtime: runtime
                  ), let description,
                  !description.isEmpty else {
                return .unreadable
            }
            source = description
        }
        guard !unidentifiedButtonNamesBus else { return .unreadable }
        return source.map(InputSlotReading.source) ?? .noSlot
    }

    // MARK: - Send slots (#291)

    /// Each send slot on a channel strip and whether it is OCCUPIED, or `nil` when the strip's
    /// descendants could not be read.
    ///
    /// Two shapes are read, and only the second has been seen on a running Logic.
    ///
    /// Measured 2026-09-27 on Logic 12.3 (6674), ko and en, on the same strip before and after a
    /// send was assigned
    /// (`docs/observations/2026-09-27-an-assigned-send-is-a-group-named-by-its-destination-beside-its-knob.json`):
    /// an EMPTY send slot is an `AXButton` whose help begins with the send-slot title and which is
    /// described only as `send button`. An ASSIGNED send is not that button. It is an `AXGroup`
    /// with no help, described by the destination (`B256` in English, `버스 256` in Korean), whose
    /// children are a bypass checkbox and a list button, and whose NEXT SIBLING is an `AXSlider`
    /// whose help begins with the send-level-knob title. Assigning the send also gave every strip
    /// in the Mixer a further empty send button, and on the assigned strip that empty button comes
    /// FIRST in the walk: the strip's children run bottom to top on screen.
    ///
    /// The first shape — a send-slot button whose pre-order successor is that knob — is what the
    /// 2026-09-13 record described. The 2026-09-27 dumps did not reproduce it in either language:
    /// the button before the knob was the new EMPTY slot with the group between them. It is still
    /// read, because a knob right after a send button can only mean that button's send, and
    /// dropping it would turn such a strip, were Logic ever to draw one, from occupied to empty.
    ///
    /// Every occupied slot reads `occupiedUnknownDestination`. The group's description does name
    /// the destination, but abbreviated in English and in full in Korean, so publishing it needs
    /// its own measurement per language; `occupiedKnownDestination` stays produced by nothing here.
    ///
    /// Occupancy is decided by the PRESENCE of the knob, never by its level: a send at minus
    /// infinity or under automation is still a send. `levelRaw` is the knob's `AXValue` when it is
    /// a finite number and `levelDescription` its `AXValueDescription` when readable; neither
    /// decides anything.
    ///
    /// Three answers are kept apart. `nil`: the list itself is unknown. Either a children read at
    /// or below the strip failed, or a read that decides whether an element is a send slot at all
    /// failed — the role of any element in the walk, the help of a button, or the help of a slider
    /// beside a group. Each of those could be a slot nobody saw: an assigned send whose knob will
    /// not give its help would otherwise read as the empty slot before it and nothing else, a list
    /// that claims to be whole and is one short. In every one of those reads -25205 and -25212 are
    /// answers and not failures — no children, no role, no help — so a slider with no help is not
    /// the knob. `[]`: the walk completed and met no send slot of either shape. `.unreadable` on
    /// one slot: its button matched but the element after it would not say whether it is the
    /// knob, so occupancy is unknown for that slot alone; the slot keeps its ordinal so the next is
    /// not renumbered. (A successor whose ROLE will not read may itself be an assigned send's
    /// group, and the walk reaches it next and returns `nil`.)
    ///
    /// The ordinal is the index among send slots of both shapes in this walk — the same pre-order,
    /// the same depth, as `slotDescription` — and not a slot number Logic assigns; on the measured
    /// strip it runs opposite to the order on screen. Unlike the output reader, this one does not
    /// pass over an element whose role or help will not read: the output reader answers one slot
    /// or `nil`, but a send slot passed over is a slot missing from a list that says it is whole.
    static func sendSlotObservations(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [SendSlotObservation]? {
        guard let walk = preOrderDescendants(of: strip, maxDepth: 4, runtime: runtime) else {
            return nil
        }
        var observations: [SendSlotObservation] = []
        for (index, visit) in walk.enumerated() {
            guard case let .success(role) = slotDecidingString(
                visit.element, kAXRoleAttribute as String, runtime: runtime
            ) else { return nil }
            if role == (kAXGroupRole as String) {
                guard let sibling = nextSibling(of: index, in: walk) else { continue }
                guard let isKnob = isSendLevelKnob(walk[sibling].element, runtime: runtime) else { return nil }
                if isKnob {
                    observations.append(
                        occupiedSendSlot(ordinal: observations.count, knob: walk[sibling].element, runtime: runtime)
                    )
                }
                continue
            }
            guard role == (kAXButtonRole as String) else { continue }
            guard case let .success(help) = slotDecidingString(
                visit.element, kAXHelpAttribute as String, runtime: runtime
            ) else { return nil }
            guard AXLocalePolicy.sendSlotHelpKeyword.containsAny(in: (help ?? "").lowercased()) else {
                continue
            }
            let successor = index + 1 < walk.count ? walk[index + 1].element : nil
            observations.append(
                sendSlotObservation(ordinal: observations.count, following: successor, runtime: runtime)
            )
        }
        return observations
    }

    /// The index of the element after `index` at the same depth with nothing shallower between —
    /// its next sibling in the walk — or `nil` when it is the last of its parent's children.
    private static func nextSibling(of index: Int, in walk: [(element: AXUIElement, depth: Int)]) -> Int? {
        let depth = walk[index].depth
        var cursor = index + 1
        while cursor < walk.count, walk[cursor].depth > depth { cursor += 1 }
        return cursor < walk.count && walk[cursor].depth == depth ? cursor : nil
    }

    /// Whether `element` is the send level knob, or `nil` when its role or help did not read: a
    /// slider that will not say what it is may be the knob of an assigned send. A role or help it
    /// does not have is an answer — not a knob.
    private static func isSendLevelKnob(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool? {
        guard case let .success(role) = slotDecidingString(element, kAXRoleAttribute as String, runtime: runtime) else {
            return nil
        }
        guard role == (kAXSliderRole as String) else { return false }
        guard case let .success(help) = slotDecidingString(element, kAXHelpAttribute as String, runtime: runtime) else {
            return nil
        }
        return AXLocalePolicy.sendLevelKnobHelpKeyword.containsAny(in: (help ?? "").lowercased())
    }

    /// A role or help that decides whether an element is part of a send slot, with the two
    /// statuses that are answers (`isDefinitiveAbsence`) read as "has none", so `.failure` is only
    /// ever a read that did not happen.
    private static func slotDecidingString(
        _ element: AXUIElement,
        _ attribute: String,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, AXHelpers.AXStatusError> {
        let read: Result<String?, AXHelpers.AXStatusError> =
            AXHelpers.getAttributeResult(element, attribute, runtime: runtime)
        if case let .failure(error) = read, error.isDefinitiveAbsence { return .success(nil) }
        return read
    }

    /// One slot's reading from the element that follows its button, if any.
    private static func sendSlotObservation(
        ordinal: Int,
        following successor: AXUIElement?,
        runtime: AXHelpers.Runtime
    ) -> SendSlotObservation {
        guard let successor else {
            return SendSlotObservation(ordinal: ordinal, state: .observedEmpty)
        }
        let role: Result<String?, AXHelpers.AXStatusError> =
            AXHelpers.getAttributeResult(successor, kAXRoleAttribute as String, runtime: runtime)
        switch role {
        case let .failure(error) where !error.isDefinitiveAbsence:
            return SendSlotObservation(ordinal: ordinal, state: .unreadable)
        case .failure:
            return SendSlotObservation(ordinal: ordinal, state: .observedEmpty)
        case let .success(value):
            guard value == (kAXSliderRole as String) else {
                return SendSlotObservation(ordinal: ordinal, state: .observedEmpty)
            }
        }
        let help: Result<String?, AXHelpers.AXStatusError> =
            AXHelpers.getAttributeResult(successor, kAXHelpAttribute as String, runtime: runtime)
        switch help {
        case let .failure(error) where !error.isDefinitiveAbsence:
            return SendSlotObservation(ordinal: ordinal, state: .unreadable)
        case .failure:
            return SendSlotObservation(ordinal: ordinal, state: .observedEmpty)
        case let .success(value):
            guard AXLocalePolicy.sendLevelKnobHelpKeyword.containsAny(in: (value ?? "").lowercased()) else {
                return SendSlotObservation(ordinal: ordinal, state: .observedEmpty)
            }
        }
        return occupiedSendSlot(ordinal: ordinal, knob: successor, runtime: runtime)
    }

    /// An occupied slot, with the level carried when it can be. A failed, non-numeric or
    /// non-finite read of the level changes nothing about the occupancy.
    private static func occupiedSendSlot(
        ordinal: Int,
        knob: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> SendSlotObservation {
        var levelRaw: Double?
        let value: Result<AnyObject?, AXHelpers.AXStatusError> =
            AXHelpers.getAttributeResult(knob, kAXValueAttribute as String, runtime: runtime)
        if case let .success(raw) = value, let number = raw as? NSNumber, number.doubleValue.isFinite {
            levelRaw = number.doubleValue
        }
        var levelDescription: String?
        let description: Result<String?, AXHelpers.AXStatusError> =
            AXHelpers.getAttributeResult(knob, kAXValueDescriptionAttribute as String, runtime: runtime)
        if case let .success(text) = description, let text, !text.isEmpty {
            levelDescription = text
        }
        return SendSlotObservation(
            ordinal: ordinal,
            state: .occupiedUnknownDestination,
            levelRaw: levelRaw,
            levelDescription: levelDescription
        )
    }

    /// Every descendant of `element` to `maxDepth`, in the order `AXHelpers.findAllDescendants`
    /// visits them and each with its depth below `element` (children are depth 1), or `nil` when a
    /// children read at any level failed with a status that is not an answer. The one way this
    /// differs from the output reader's walk: that one flattens a failed read into "no children",
    /// which is the absence-as-claim an absent `send_slots` exists to refuse. The depth is what
    /// lets a group be paired with its next SIBLING rather than with its own last descendant.
    private static func preOrderDescendants(
        of element: AXUIElement,
        maxDepth: Int,
        runtime: AXHelpers.Runtime,
        depth: Int = 1
    ) -> [(element: AXUIElement, depth: Int)]? {
        guard maxDepth > 0 else { return [] }
        guard let children = childrenIfRead(element, runtime: runtime) else { return nil }
        var visited: [(element: AXUIElement, depth: Int)] = []
        for child in children {
            visited.append((child, depth))
            guard let below = preOrderDescendants(
                of: child, maxDepth: maxDepth - 1, runtime: runtime, depth: depth + 1
            ) else {
                return nil
            }
            visited.append(contentsOf: below)
        }
        return visited
    }

    /// The leading sentence of every direct child's `AXHelp` on a channel strip, or `nil` when the
    /// child list could not be read (#766).
    ///
    /// `nil` and `[]` are kept apart on purpose. A strip nobody could read otherwise reports no
    /// slots, and every clause phrased as an ABSENCE — "no output slot", "no audio effect slot" —
    /// then passes over it and classifies it confidently. The census this was derived from gained
    /// the same distinction from a review on 2026-09-08 for exactly that reason.
    ///
    /// Direct children only, because that is where the measurement was taken: the slots sit on the
    /// strip itself, and descending further would pull in the inserted plug-ins' own controls.
    static func slotKinds(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [String]? {
        guard case let .success(children) = AXHelpers.childrenResult(strip, runtime: runtime) else {
            return nil
        }
        var kinds: [String] = []
        for child in children {
            // A help read that FAILED is not a child without help. Flattening both to "" made a
            // present output slot whose label could not be read look like "no output slot", and the
            // external-MIDI clause is phrased as an absence — so an unreadable label could produce a
            // confident `externalMIDI`. A readable child LIST does not prove every child's label was
            // read. Found by review 2026-09-09.
            let read: Result<String?, AXHelpers.AXStatusError> =
                AXHelpers.getAttributeResult(child, kAXHelpAttribute as String, runtime: runtime)
            switch read {
            case let .failure(error):
                // A child that simply HAS no help is not a child whose help could not be read.
                // Measured live 2026-09-09 on one strip: 20 children answer success and 8 answer
                // `kAXErrorNoValue`. Refusing on the whole non-success set made every strip
                // undetermined and the feature silently dead — the live harness caught it, no unit
                // test could have. Only a genuine read failure refuses.
                guard error.raw == AXError.noValue.rawValue
                    || error.raw == AXError.attributeUnsupported.rawValue else { return nil }
                continue
            case let .success(value):
                let help = value ?? ""
                guard let dot = help.firstIndex(of: ".") else { continue }
                kinds.append(String(help[help.startIndex..<dot]).lowercased())
            }
        }
        return kinds
    }

    /// What the SELECTED track's inspector channel strip says the track is (#766).
    ///
    /// Measured 2026-09-09 on Logic 12.3 (6674), en, on tracks created by each `create_*`:
    ///
    ///     Input slot                                    audio
    ///     MIDI Effect slot                              software instrument OR DRUMMER
    ///     no output slot + an Assign control row        external MIDI
    ///
    /// The middle row is why this returns a THREE-valued reading rather than a `TrackType`: a drummer track's
    /// strip is identical to a software instrument's, so the honest answer for that shape is no
    /// answer, and the caller keeps whatever the header said. Returning `.softwareInstrument` there
    /// would be a confident wrong answer on every drummer track.
    ///
    /// External MIDI is the one claim here resting on an ABSENCE, so it is made only from a child
    /// list that was actually read: `slotKinds` returns `nil` rather than `[]` when it was not, and
    /// this refuses on `nil` instead of reading it as "no output slot".
    static func inspectorStripReading(
        expectedName: String,
        settleAttempts: Int = 20,
        settleInterval: useconds_t = 50_000,
        runtime: Runtime = .production
    ) -> StripReading {
        guard let window = mainWindow(runtime: runtime),
              let strip = inspectorChannelStrip(named: expectedName, in: window, runtime: runtime.ax)
        else { return .undetermined }

        // TWICE, and they must agree. The strip's NAME can arrive before its SLOTS do — measured
        // 2026-09-08 and written into `Scripts/observations/reverify-inspector-strip-type-slots.sh`:
        // the first run after a rebuild put a `Studio Grand` strip in `neither` and the three runs
        // after it agreed. So settling on the name does NOT close the rebuild race, and a rule read
        // once off a surface that is still catching up is a reading of the transition rather than of
        // the state. Found by review 2026-09-09, which cited this project's own note back at it.
        let value = settledReading(attempts: settleAttempts, interval: settleInterval) {
            slotKinds(in: strip, runtime: runtime.ax)
        }
        // The strip must STILL be the one we acquired. Two equal readings prove the slots stopped
        // moving; they do not prove the strip did not become a different track's midway. Re-reading
        // the name afterwards closes that, and it is the part of the freshness question that CAN be
        // closed cheaply.
        //
        // What it does NOT close, stated because a review asked for it and the answer is a residual
        // rather than a fix: two consecutive PRE-rebuild readings also agree, so a strip whose name
        // has already changed while its slots have not yet been rebuilt settles on the old slots.
        // Requiring an observed TRANSITION instead would refuse the ordinary case, where the strip
        // is already correct when it is acquired and never changes. Bounding staleness therefore
        // rests on the create path's own settling in front of this, and the honest description of
        // this rule is "the slots stopped moving and the strip is still the same one", not "the
        // slots are fresh".
        guard AXHelpers.getDescription(strip, runtime: runtime.ax) == expectedName else {
            return .undetermined
        }
        return value
    }

    /// Reads slot kinds until two consecutive readings AGREE, then classifies.
    ///
    /// Split from the live lookup so the stability rule can be driven directly: a test that has to
    /// stand up a whole window cannot easily make the slots change between reads, and a rule nothing
    /// exercises is a rule nothing checks. Measured by mutation — collapsing this to a single read
    /// left the rest of the suite green.
    static func settledReading(
        attempts: Int,
        interval: useconds_t,
        read: () -> [String]?
    ) -> StripReading {
        var previous: [String]?
        for attempt in 0..<max(1, attempts) {
            let current = read()
            // An unreadable child list is not a state to settle on: it is refused outright rather
            // than compared against the next read, which could agree with it for the wrong reason.
            guard current != nil else { return .undetermined }
            if let previous, previous == current { return reading(fromSlotKinds: current) }
            previous = current
            if attempt + 1 < max(1, attempts) { usleep(interval) }
        }
        return .undetermined
    }

    /// What a strip's slots amount to (#766).
    ///
    /// `instrumentFamily` is a THIRD answer rather than a second spelling of `undetermined`,
    /// because the two are different facts and the create path publishes them differently: one
    /// says the strip was read and its answer is a family this read cannot narrow, the other says
    /// no strip answered. Collapsing them would also make the MIDI-effect branch unobservable —
    /// it would return the same thing as falling through, and a rule nothing can distinguish is
    /// not a rule.
    enum StripReading: Equatable {
        case type(TrackType)
        case instrumentFamily
        case undetermined
    }

    /// The classification itself, separated from reading it off a live strip so it can be tested
    /// against the shapes that were measured rather than only against a running Logic (#766).
    ///
    /// `nil` in means the child list was unreadable and `nil` out is the only correct answer: the
    /// external-MIDI clause is phrased as an absence, and a strip nobody could read shows no output
    /// slot either.
    static func reading(fromSlotKinds kinds: [String]?) -> StripReading {
        guard let kinds else { return .undetermined }
        let has = { (set: AXLocalePolicy.LabelSet) in kinds.contains { set.containsAny(in: $0) } }

        // The three signals are COUNTED, not tried in order. Ordering them made source position
        // decide every shape the census did not sample: the sampled strips are disjoint, so
        // swapping the first two branches left every fixture green while changing the answer for
        // any strip carrying both. That is the same defect as the header classifier's
        // first-match-wins, which is what #766 is about. Found by review 2026-09-09.
        let inputSlot = has(AXLocalePolicy.inputSlotHelpKeyword)
        let midiEffectSlot = has(AXLocalePolicy.midiEffectSlotHelpKeyword)
        // External MIDI rests on ABSENCES, and one unreadable label must not be able to fake them.
        // A review traced it: a strip with a readable `Assign control` child and an output slot
        // whose help answers `noValue` yields `["assign control"]`, and a rule of "assign control
        // and no output slot" then answers external MIDI for an ordinary strip.
        //
        // So the audio path must be absent in THREE places at once. Measured 2026-09-09: the
        // external-MIDI strip (`Off 1`) has no output slot, no send slot and no audio effect slot,
        // and carries four `Assign control` rows; every other strip in that project has all three.
        // One unreadable label cannot produce that shape — three would have to fail together on the
        // one strip that also carries assign controls.
        //
        // It is still an absence rule and still the weakest clause here. The recorded limit on this
        // file (`45d6a4b6`) — an unfound output slot means "not identified", never "routed nowhere"
        // — still applies. This raises the number of coincidences a wrong answer needs; it does not
        // remove the class.
        let externalMIDIShape = has(AXLocalePolicy.assignControlHelpKeyword)
            && !has(AXLocalePolicy.outputSlotHelpKeyword)
            && !has(AXLocalePolicy.sendOrIOControlLabel)
            && !has(AXLocalePolicy.audioPluginSlotLabel)

        let signals = [inputSlot, midiEffectSlot, externalMIDIShape].filter { $0 }.count
        guard signals == 1 else { return .undetermined }

        if inputSlot { return .type(.audio) }
        // A drummer strip is identical to a software instrument's, so the family is where this
        // stops. Narrowing here is the confident wrong answer #766's first half removed.
        if midiEffectSlot { return .instrumentFamily }
        return .type(.externalMIDI)
    }

    /// The inspector's channel strip for the SELECTED track, or `nil` (#766).
    ///
    /// The inspector rebuilds this strip when the selection changes, so the caller must say which
    /// track it expects and this refuses until the strip's own name agrees. Without that wait the
    /// read races the rebuild and reports the PREVIOUS track's strip, which looks like a settled
    /// answer. Two tracks with the same name defeat the agreement and that is not detectable here.
    static func inspectorChannelStrip(
        named expected: String,
        in window: AXUIElement,
        settleAttempts: Int = 40,
        settleInterval: useconds_t = 50_000,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        // The inspector REBUILDS this strip when the selection changes, and the rebuild is not
        // finished when the operation that changed the selection returns. Reading once made the
        // answer a race: the strip still names the previous track, the name does not agree, and the
        // read degrades to the header's `unknown` — intermittently, which is worse than never.
        //
        // Bounded, because the other reason the name never agrees is that it never will: a name
        // that was not live-identity-backed, or two tracks sharing one.
        for attempt in 0..<max(1, settleAttempts) {
            if let only = soleInspectorStrip(named: expected, in: window, runtime: runtime) {
                return only
            }
            if attempt + 1 < max(1, settleAttempts) { usleep(settleInterval) }
        }
        return nil
    }

    /// The one inspector strip carrying `expected`, or nil when there is not exactly one.
    ///
    /// Split out of the settle loop so the candidate set is counted at one place instead of once
    /// per attempt — `Scripts/check-ax-locator-census.py` reads the SHAPE of a lookup, and a
    /// count-and-refuse written inside a loop reads to it as a reduction to the first hit.
    ///
    /// EXACTLY ONE, or no answer. Returning the first of several published the OLD track's type
    /// confidently whenever two tracks share a name — the ticket admitted that identity weakness
    /// and the code promoted the ambiguous match anyway. Refusing is the rule the rest of this file
    /// already applies. Found by review 2026-09-09.
    private static func soleInspectorStrip(
        named expected: String,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let matches = AXHelpers.findAllDescendants(
            of: window, role: kAXLayoutItemRole as String, maxDepth: 8, runtime: runtime
        ).filter { item in
            let help = AXHelpers.getHelp(item, runtime: runtime) ?? ""
            guard AXLocalePolicy.inspectorChannelStripHelpPrefix.hasPrefixAny(help) else {
                return false
            }
            return AXHelpers.getDescription(item, runtime: runtime) == expected
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            Log.info("soleInspectorStrip: \(matches.count) strips are named \(expected); "
                + "refusing rather than returning the first in tree order", subsystem: "ax")
        }
        return nil
    }

    /// The sliders among `sliders` that satisfy `volumeFaderSelector`, judged one at a time.
    ///
    /// #290. Shared so a caller that has ALREADY enumerated a subtree judges volume identity over
    /// that same array rather than over a fresh walk of the tree, which can read differently.
    static func volumeFaderCandidates(
        among sliders: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement] {
        sliders.filter { slider in
            let candidate = AXResolvableCandidate.make(from: slider, runtime: runtime)
            return resolve(volumeFaderSelector, in: [candidate], locale: "any") == .exact(index: 0)
        }
    }

    static func findVolumeFader(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(
            of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        // Second atlas adoption. This site had BOTH of the shapes ADR-007 exists to remove: it
        // returned the first description match when several qualified, and it fell back to
        // `sliders.first` — position 0 — when none did. Routing it through the resolver removes
        // both, because `failClosed` refuses an ambiguous set and there is no positional path to
        // fall into.
        let candidates = volumeFaderCandidates(among: sliders, runtime: runtime)
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 {
            Log.info("findVolumeFader: \(candidates.count) sliders satisfy the volume selector; "
                + "refusing rather than returning the first in tree order", subsystem: "ax")
            return nil
        }
        // Measured 2026-08-21 on Logic 12.3, and again through the census since: a strip has two
        // sliders and one of them names itself, so this branch is not reached. It used to return
        // position 0 anyway. A tree that reaches it is one this code has never been measured
        // against, and answering with an index there is the wrong-target behaviour the ADR names.
        if !sliders.isEmpty {
            Log.info("findVolumeFader: no slider among \(sliders.count) satisfies the volume "
                + "selector; refusing rather than falling back to position 0", subsystem: "ax")
        }
        return nil
    }

    /// The atlas selector for a volume fader, on a track header or a mixer strip.
    ///
    /// Evidence is the alias set across the fields Logic might carry the name in, and nothing else.
    ///
    /// `anyAttributeContainsAny`, not two per-attribute predicates: those are ANDed, and naming
    /// both `AXHelp` and `AXDescription` demands the label appear in both. Logic puts a header
    /// fader's name in `AXDescription` and its sentence in `AXHelp`, a synthetic fixture carries
    /// only the description, and the conjunction matched neither reliably — the existing mixer
    /// tests caught that draft.
    ///
    /// A `valueSignature` is deliberately ABSENT. The header fader was measured at `0...233`; the
    /// mixer strip's range was not, and a selector asserting a number nobody read is the failure
    /// this whole sequence has been about. The aliases discriminate on their own — the pan slider
    /// carries none of `volume` / `fader` / `볼륨` in any of these fields — which is what
    /// `sliderText(_:).isVolumeFader` already relied on.
    static let volumeFaderSelector = SemanticSelector(
        id: .trackHeaderVolumeFader,
        requiredRole: kAXSliderRole as String,
        allowedSubroles: [],
        titleAliases: [:],
        ancestorConstraints: [],
        attributePredicates: [
            .attributes([kAXHelpAttribute as String,
                         kAXDescriptionAttribute as String,
                         kAXRoleDescriptionAttribute as String],
                        anyOf: AXLocalePolicy.sliderVolumeHint.labels, mode: .contains),
        ],
        geometryHint: nil,
        minimumConfidence: 0.6,
        ambiguityPolicy: .failClosed
    )

    static func findPanControl(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production,
        requireUnique: Bool = false
    ) -> AXUIElement? {
        let failures = AXPluginInstanceIdentity.FailedReads()
        let ax = requireUnique ? AXPluginInstanceIdentity.noting(failures, over: runtime) : runtime
        let sliders: [AXUIElement]
        if requireUnique {
            guard let walk = preOrderDescendants(of: strip, maxDepth: 4, runtime: ax) else { return nil }
            var observed: [AXUIElement] = []
            for visit in walk {
                if visit.depth == 4 {
                    guard let children = childrenIfRead(visit.element, runtime: ax), children.isEmpty else { return nil }
                }
                let role: Result<String?, AXHelpers.AXStatusError> =
                    AXHelpers.getAttributeResult(visit.element, kAXRoleAttribute as String, runtime: ax)
                // A missing role is a possible competing slider, not a non-slider.
                guard case .success(.some(let value)) = role, !value.isEmpty else { return nil }
                if value == kAXSliderRole as String { observed.append(visit.element) }
            }
            sliders = observed
        } else {
            sliders = AXHelpers.findAllDescendants(
                of: strip, role: kAXSliderRole, maxDepth: 4, runtime: ax
            )
        }
        let described = sliders.filter { sliderText($0, runtime: ax).isPanControl }
        if requireUnique {
            guard !failures.any else { return nil }
            if described.count == 1 { return described[0] }
            if described.count > 1 { return nil }
            // Reuse the header selector's existing two-slider/one-named-volume elimination,
            // without assigning physical pan from a slider's position in the strip.
            let volumes = volumeFaderCandidates(among: sliders, runtime: ax)
            guard !failures.any, sliders.count == 2, volumes.count == 1 else { return nil }
            return sliders.first { !CFEqual($0, volumes[0]) }
        }
        if let only = described.first {
            if described.count > 1 {
                Log.info("findPanControl: \(described.count) sliders described as a pan control; "
                    + "returning the first in tree order", subsystem: "ax")
            }
            return only
        }
        // `sliders[1]` — identity from tree order, written as an index. Same measurement as the
        // fader above: not reached on a strip whose pan slider carries a description. Silence here
        // would make "the description matched" and "the second slider happened to be pan"
        // indistinguishable, and only one of those is a fact about this strip.
        if sliders.count > 1 {
            Log.info("findPanControl: no slider described as a pan control among \(sliders.count); "
                + "falling back to position 1", subsystem: "ax")
        }
        return sliders.count > 1 ? sliders[1] : nil
    }

}
