import ApplicationServices
import Foundation


extension AXLogicProElements {
    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }

        // Legacy/test-path lookup. Older Logic builds and existing fake AX
        // trees expose the mixer with AXIdentifier="Mixer".
        if let mixer = AXHelpers.findDescendant(
            of: window, role: kAXGroupRole, identifier: "Mixer", runtime: runtime.ax
        ) {
            return mixer
        }
        if let mixer = AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Mixer", runtime: runtime.ax
        ) {
            return mixer
        }

        // #234: Logic Pro 12.2 exposes the visible bottom Mixer as:
        //   AXGroup(desc:"믹서") -> AXLayoutArea(desc:"믹서") -> AXLayoutItem strips
        // with no AXIdentifier. Logic Pro 12.3 wraps that layout area with an
        // outer AXGroup(desc:"Mixer") and a sibling toolbar AXGroup(desc:"Mixer").
        // Do not fall back to the Inspector's small two-strip "믹서" area; that
        // would make a full mixer read silently return only selected-track +
        // output strips.
        return mixerAreaCandidates(in: window, runtime: runtime.ax)
            .sorted { lhs, rhs in
                if lhs.stripCount != rhs.stripCount { return lhs.stripCount > rhs.stripCount }
                return lhs.totalChildCount > rhs.totalChildCount
            }
            .first?
            .element
    }

    /// #107: the per-track volume fader inside the track HEADER (an AXSlider
    /// whose value-indicator reads "Volume"). Same channel parameter as the
    /// mixer-strip fader, but identity-safe — it belongs to exactly track
    /// `index` — and always present without the Mixer being visible. Logic
    /// ignores AXValue writes on it, so callers drive it with
    /// AXIncrement/AXDecrement detents.
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
        id: .mixerStripVolumeFader,
        requiredRole: kAXSliderRole as String,
        allowedSubroles: [],
        titleAliases: [:],
        ancestorConstraints: [AncestorConstraint(role: "AXLayoutItem")],
        attributePredicates: [
            .attributeContainsAny(kAXHelpAttribute as String, AXLocalePolicy.sliderPanHint.labels),
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
        let volume = findVolumeFader(in: header, runtime: runtime)
        let eliminated = sliders.first { volume == nil || !CFEqual($0, volume!) }
        if eliminated != nil {
            Log.info("findPanControlInHeader: no slider among \(sliders.count) carries a pan "
                + "identity; selecting by elimination against the volume fader", subsystem: "ax")
        }
        return eliminated
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime) else { return nil }
        let strips = mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        return findVolumeFader(in: strip, runtime: runtime.ax)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime) else { return nil }
        let strips = mixerChannelStrips(in: mixer, runtime: runtime.ax)
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
    ) -> [MixerAreaCandidate] {
        var candidates: [MixerAreaCandidate] = []
        collectMixerAreaCandidates(
            root,
            runtime: runtime,
            depth: 0,
            ancestorIsInspector: false,
            into: &candidates
        )
        return candidates
    }

    private static func collectMixerAreaCandidates(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime,
        depth: Int,
        ancestorIsInspector: Bool,
        into candidates: inout [MixerAreaCandidate]
    ) {
        guard depth <= 12 else { return }

        let text = elementSearchText(element, runtime: runtime)
        let isInspector = ancestorIsInspector
            || AXLocalePolicy.mixerInspectorContext.containsAny(in: text)

        if !isInspector,
           isMixerNamedElement(element, runtime: runtime),
           isMixerContainerRole(AXHelpers.getRole(element, runtime: runtime)),
           hasDirectChannelStripChildren(element, runtime: runtime) {
            let strips = channelStripLayoutItems(in: element, runtime: runtime)
            candidates.append(MixerAreaCandidate(
                element: element,
                stripCount: strips.count,
                totalChildCount: AXHelpers.getChildren(element, runtime: runtime).count
            ))
        }

        for child in AXHelpers.getChildren(element, runtime: runtime) {
            collectMixerAreaCandidates(
                child,
                runtime: runtime,
                depth: depth + 1,
                ancestorIsInspector: isInspector,
                into: &candidates
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
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { AXLocalePolicy.mixerNamedElement.labels.contains($0) }
    }

    private static func hasDirectChannelStripChildren(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        !channelStripLayoutItems(in: element, runtime: runtime).isEmpty
    }

    private static func channelStripLayoutItems(
        in element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement] {
        AXHelpers.getChildren(element, runtime: runtime).filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXLayoutItemRole as String)
        }
    }

    static func mixerChannelStrips(
        in mixer: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [AXUIElement] {
        stripEnumeration(in: mixer, runtime: runtime).strips
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
        let enumeration = stripEnumeration(in: mixer, runtime: runtime)
        guard enumeration.unreadableChildren == 0 else { return nil }
        return enumeration
    }

    /// The strips, plus whether any child's role could not be read.
    ///
    /// A child whose role is unreadable is dropped by the filter, and every later strip then moves
    /// down one. Callers address strips by ORDINAL, so a request for track 0 would act on physical
    /// strip 1 — a wrong-target write that no downstream readback can catch, because the readback
    /// reads the same shifted list. The count is returned so a mutating caller can refuse instead of
    /// addressing a list it cannot trust. A read-only caller may still use the strips.
    static func stripEnumeration(
        in mixer: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> (strips: [AXUIElement], unreadableChildren: Int) {
        let children = AXHelpers.getChildren(mixer, runtime: runtime)
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

    /// The description of the first slot button whose help matches, or nil.
    ///
    /// Shared by the input and output readers so the two cannot drift apart — a second copy of this
    /// walk is a second place for the "found it but it named nothing" case to be decided differently.
    private static func slotDescription(
        in strip: AXUIElement,
        matching keyword: AXLocalePolicy.LabelSet,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let buttons = AXHelpers.findAllDescendants(
            of: strip, role: kAXButtonRole, maxDepth: 4, runtime: runtime
        )
        for button in buttons {
            let help = AXHelpers.getHelp(button, runtime: runtime) ?? ""
            guard keyword.containsAny(in: help.lowercased()) else { continue }
            guard let description = AXHelpers.getDescription(button, runtime: runtime),
                  !description.isEmpty else {
                // The slot was found and did not name anything. That is a gap, not an empty route,
                // so it reads the same as not finding the slot at all.
                return nil
            }
            return description
        }
        return nil
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
        let candidates = sliders.filter { slider in
            let candidate = AXResolvableCandidate.make(from: slider, runtime: runtime)
            return resolve(volumeFaderSelector, in: [candidate], locale: "any") == .exact(index: 0)
        }
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
        id: .mixerStripVolumeFader,
        requiredRole: kAXSliderRole as String,
        allowedSubroles: [],
        titleAliases: [:],
        ancestorConstraints: [],
        attributePredicates: [
            .anyAttributeContainsAny(
                [kAXHelpAttribute as String,
                 kAXDescriptionAttribute as String,
                 kAXRoleDescriptionAttribute as String],
                AXLocalePolicy.sliderVolumeHint.labels),
        ],
        geometryHint: nil,
        minimumConfidence: 0.6,
        ambiguityPolicy: .failClosed
    )

    static func findPanControl(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(
            of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        let described = sliders.filter { sliderText($0, runtime: runtime).isPanControl }
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
