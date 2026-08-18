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

    /// Header-level pan-slider selection (split out for deterministic testing).
    static func findPanControlInHeader(_ header: AXUIElement, runtime: AXHelpers.Runtime = .production) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(of: header, role: kAXSliderRole, maxDepth: 4, runtime: runtime)
        if let pan = sliders.first(where: { slider in
            AXHelpers.getChildren(slider, runtime: runtime).contains { child in
                let desc = (AXHelpers.getDescription(child, runtime: runtime) ?? "").lowercased()
                return AXLocalePolicy.headerPanHint.containsAny(in: desc)
            }
        }) {
            return pan
        }
        // Fallback: the slider that is NOT the volume fader.
        let volume = findVolumeFader(in: header, runtime: runtime)
        return sliders.first { volume == nil || !CFEqual($0, volume!) }
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
        if let described = sliders.first(where: { sliderText($0, runtime: runtime).isVolumeFader }) {
            return described
        }
        return sliders.first
    }

    static func findPanControl(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(
            of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        if let described = sliders.first(where: { sliderText($0, runtime: runtime).isPanControl }) {
            return described
        }
        return sliders.count > 1 ? sliders[1] : nil
    }

}
