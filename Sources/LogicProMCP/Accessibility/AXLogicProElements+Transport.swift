import ApplicationServices
import Foundation


extension AXLogicProElements {
    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }

        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole, runtime: runtime.ax) {
            return toolbar
        }
        if let toolbar = AXHelpers.findDescendant(of: window, role: kAXToolbarRole, maxDepth: 6, runtime: runtime.ax),
           looksLikeTransportContainer(toolbar, runtime: runtime.ax) {
            return toolbar
        }
        if let group = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport", runtime: runtime.ax) {
            return group
        }

        // #628: the discriminated sibling accessor, before the keyword scan that guesses.
        //
        // This composition is not new to the codebase — `AccessibilityChannel+Transport.swift:11`
        // already writes `getControlBar() ?? getTransportBar()` at a call site. Folding it in here
        // needs no answer to "is a transport bar a control bar", because `getControlBar` returns an
        // element only when exactly one labelled group holds a checkbox and nil otherwise: when it
        // answers, it has identified something; when it does not, the scan below runs exactly as
        // before.
        //
        // Measured on Logic 12.3 before making the change: `getControlBar()` resolves, and it
        // returns THE SAME element the scan was taking first. So this is observationally a no-op on
        // the machine it was measured on, and the difference is only visible on a tree where the
        // scan's first survivor is not the control bar — which is the tree nobody has seen and the
        // reason the scan was wrong to guess.
        if let identified = getControlBar(runtime: runtime) {
            return identified
        }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax)
        let survivors = transportContainerCandidates(among: groups, runtime: runtime)
        if let candidate = survivors.first {
            // #628: the element returned is UNCHANGED — still the first survivor in tree order.
            // What changes is that a tree-order choice among several now says so.
            //
            // Measured on Logic 12.3, one project, one track: thirty-seven groups gathered, FOUR
            // survive. Two of the four are the arrange area, because the predicate accepts any
            // container holding two or more transport-keyword controls and a track header holds a
            // record-arm checkbox. The keyword bag cannot tell "record-arm this track" from
            // "record".
            //
            // Deliberately not a refusal. Which of the four this accessor SHOULD return is a
            // question about its contract — whether "transport bar" and "control bar" name the same
            // thing — and that is a decision, not a measurement. A discriminator is available when
            // someone makes it: description narrows four to two, and #633's "holds a checkbox"
            // separates those two.
            // Reached only when `getControlBar` could NOT identify one, so a count above one here
            // now means both the discriminated route and the keyword scan failed to resolve — a
            // strictly narrower and more interesting event than before.
            //
            // Written to stderr, which the live-evidence harness discards
            // (`Scripts/livekit/evidence.py:184` runs the server with `stderr=DEVNULL`). So this
            // reaches an operator reading the server log and does NOT reach the evidence document.
            // Said here rather than left implied, because a line that cannot reach the channel the
            // gate reads is not "making it visible" to the gate.
            if survivors.count > 1 {
                Log.info(
                    "getTransportBar: getControlBar did not identify one, and \(survivors.count) "
                        + "groups matched looksLikeTransportContainer; returning the first in tree order",
                    subsystem: "ax"
                )
            }
            return candidate
        }

        return looksLikeTransportContainer(window, runtime: runtime.ax) ? window : nil
    }

    /// Every group the transport scan accepts, in tree order — split out so the count is a value a
    /// test can assert on rather than a number that exists only inside an `if let`.
    ///
    /// `first` of this is exactly what the previous `groups.first(where:)` returned, so extracting
    /// it changes nothing about which element is chosen.
    static func transportContainerCandidates(
        among groups: [AXUIElement],
        runtime: Runtime = .production
    ) -> [AXUIElement] {
        groups.filter { looksLikeTransportContainer($0, runtime: runtime.ax) }
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String, runtime: Runtime = .production) -> AXUIElement? {
        guard let transport = getTransportBar(runtime: runtime) else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(
            of: transport, role: kAXButtonRole, title: name, runtime: runtime.ax
        ) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4, runtime: runtime.ax)
        for button in buttons {
            if AXHelpers.getDescription(button, runtime: runtime.ax) == name {
                return button
            }
        }
        return nil
    }

    /// Locate Logic Pro 12's control bar (컨트롤 막대 / Control Bar) — the AXGroup
    /// below the main arrange area that contains Play, Record, Cycle, Metronome,
    /// etc. as AXCheckBox widgets.
    static func getControlBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }

        // #628: "Control Bar" is not a unique AXDescription. Measured on one arrange window, two
        // groups carry it — (10, 54, 1900, 58) with twenty direct checkboxes, and
        // (828, 58, 264, 48) with none. The loop that used to be here returned whichever the walk
        // reached first, which is the right one today and says nothing about why.
        //
        // The discriminator is the property callers actually depend on: this is the bar you can
        // find a transport control in. `findControlBarCheckbox` and its siblings all immediately
        // search it for a checkbox, so a candidate holding none cannot be what they meant, whatever
        // it is called.
        let labelled = AXHelpers.findAllDescendants(
            of: window, role: kAXGroupRole, maxDepth: 8, runtime: runtime.ax
        ).filter { group in
            AXLocalePolicy.controlBarGroupLabel.matches(
                AXHelpers.getDescription(group, runtime: runtime.ax) ?? "", mode: .exactStrict
            )
        }
        let withControls = labelled.filter { group in
            AXHelpers.getChildren(group, runtime: runtime.ax).contains { child in
                AXHelpers.getRole(child, runtime: runtime.ax) == kAXCheckBoxRole as String
            }
        }
        // Exactly one, or nothing. Two bars that both hold transport controls is a tree this code
        // has never seen and must not guess about; the callers all fail closed on nil.
        if withControls.count == 1 { return withControls[0] }
        // No labelled candidate holds a control: fall back to a lone labelled group rather than
        // regressing to first-of-many, so a Logic that renders the bar differently still resolves.
        if withControls.isEmpty, labelled.count == 1 { return labelled[0] }
        return nil
    }

    /// Find an AXCheckBox inside Logic Pro's control bar by its name.
    /// Common names (Korean): `녹음` (Record), `재생` (Play), `사이클` (Cycle),
    /// `카운트 인` (Count-in), `메트로놈 클릭` (Metronome).
    /// English equivalents are also attempted as a fallback.
    static func findControlBarCheckbox(
        named koreanName: String,
        englishName: String? = nil,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let localeLabels: AXLocalePolicy.LabelSet? = switch englishName {
        case "Play": AXLocalePolicy.transportPlayControl
        case "Record": AXLocalePolicy.transportRecordControl
        case "Cycle": AXLocalePolicy.transportCycleControl
        case "Metronome": AXLocalePolicy.transportMetronomeControl
        default: nil
        }
        let checkboxes = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime.ax
        )
        // Prefer title match (AXTitle) — which is what `name of` returns in AS
        for cb in checkboxes {
            let title = AXHelpers.getTitle(cb, runtime: runtime.ax) ?? ""
            if title == koreanName { return cb }
            if let en = englishName, title == en { return cb }
            if localeLabels?.matches(title, mode: .exactStrict) == true { return cb }
        }
        // Fallback: description match
        for cb in checkboxes {
            let desc = AXHelpers.getDescription(cb, runtime: runtime.ax) ?? ""
            if desc == koreanName { return cb }
            if let en = englishName, desc == en { return cb }
            if localeLabels?.matches(desc, mode: .exactStrict) == true { return cb }
        }
        return nil
    }

    static func findControlBarCheckbox(
        matching labels: AXLocalePolicy.LabelSet,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        // #628: the scope is the discriminator, and until now nothing said so. Measured on one
        // arrange window, "Solo" matches TWENTY checkboxes — one in the Control Bar and nineteen
        // track buttons. Scoping to the bar makes it unique, so `findDescendant` returned the right
        // element; it also would have returned SOME element, silently, had the scope ever widened.
        // Toggling a random track's solo instead of the transport's is the failure that hides
        // behind first-match.
        let census = AXLocalePolicy.censusDescendant(
            of: controlBar,
            role: kAXCheckBoxRole,
            matching: labels,
            maxDepth: 4,
            runtime: runtime.ax
        )
        return census.element
    }

    /// Find the `bar` component of Logic Pro's Control Bar playhead-position
    /// group. Its AX value is not assumed to be an absolute bar position.
    static func findControlBarBarSlider(runtime: Runtime = .production) -> AXUIElement? {
        findControlBarPlayheadPositionSlider(
            matching: AXLocalePolicy.barSliderLabel,
            runtime: runtime
        )
    }

    /// Locate a component slider below the named Playhead Position group. Logic
    /// 12.3 nests `bar` and `beat` beneath that group more deeply than the
    /// historical four-level control-bar scan, so resolve the structural owner
    /// first and then traverse its complete descendant subtree.
    private static func findControlBarPlayheadPositionSlider(
        matching labels: AXLocalePolicy.LabelSet,
        runtime: Runtime
    ) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let groups = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXGroupRole, maxDepth: 8, runtime: runtime.ax
        )
        guard let playheadPosition = groups.first(where: {
            AXLocalePolicy.playheadPositionGroupLabel.matches(
                AXHelpers.getDescription($0, runtime: runtime.ax), mode: .exactStrict
            )
        }) else { return nil }
        let componentSliders = AXHelpers.findAllDescendants(
            of: playheadPosition, role: kAXSliderRole, maxDepth: 8, runtime: runtime.ax
        )
        guard componentSliders.count == 2,
              componentSliders.contains(where: {
                  AXLocalePolicy.barSliderLabel.matches(
                      AXHelpers.getDescription($0, runtime: runtime.ax), mode: .exactStrict
                  )
              }),
              componentSliders.contains(where: {
                  AXLocalePolicy.beatSliderLabel.matches(
                      AXHelpers.getDescription($0, runtime: runtime.ax), mode: .exactStrict
                  )
              })
        else { return nil }
        return componentSliders.first(where: {
            labels.matches(AXHelpers.getDescription($0, runtime: runtime.ax), mode: .exactStrict)
        })
    }

    /// Find the 템포 / Tempo slider in Logic's control bar. Double-clicking
    /// this slider opens an inline numeric-entry overlay (see
    /// AXMouseHelper.doubleClick for the exact interaction).
    ///
    /// Search order:
    ///   1. `getControlBar()` subtree (production path — AXGroup "컨트롤 막대")
    ///   2. `getTransportBar()` subtree (fallback — AXToolbar or "Transport" group)
    ///   3. Main window's entire slider descendants (last-resort, also covers
    ///      test doubles that build a minimal AX tree without the wrapper groups)
    static func findTempoSlider(runtime: Runtime = .production) -> AXUIElement? {
        let searchRoots: [AXUIElement] = [
            getControlBar(runtime: runtime),
            getTransportBar(runtime: runtime),
            mainWindow(runtime: runtime),
        ].compactMap { $0 }

        for root in searchRoots {
            let sliders = AXHelpers.findAllDescendants(
                of: root, role: kAXSliderRole, maxDepth: 8, runtime: runtime.ax
            )
            for s in sliders {
                let desc = (AXHelpers.getDescription(s, runtime: runtime.ax) ?? "").lowercased()
                if AXLocalePolicy.tempoSliderLabel.matches(desc, mode: .exactStrict) {
                    return s
                }
            }
        }
        return nil
    }

    /// Find the `beat` component below Logic Pro 12.3's Playhead Position group.
    static func findControlBarBeatSlider(runtime: Runtime = .production) -> AXUIElement? {
        findControlBarPlayheadPositionSlider(
            matching: AXLocalePolicy.beatSliderLabel,
            runtime: runtime
        )
    }

    /// Read the current value (0/1) of a control-bar checkbox. Returns nil if
    /// the element can't be located or its value is not readable.
    static func readControlBarCheckboxValue(
        named koreanName: String,
        englishName: String? = nil,
        runtime: Runtime = .production
    ) -> Bool? {
        guard let cb = findControlBarCheckbox(
            named: koreanName, englishName: englishName, runtime: runtime
        ) else { return nil }
        if let n: NSNumber = AXHelpers.getAttribute(cb, kAXValueAttribute, runtime: runtime.ax) {
            return n.boolValue
        }
        if let b: Bool = AXHelpers.getAttribute(cb, kAXValueAttribute, runtime: runtime.ax) {
            return b
        }
        return nil
    }

}
