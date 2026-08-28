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
        // The identified bar must still SATISFY the thing callers want from it. `getControlBar`
        // ends with a branch that returns a lone labelled group holding no checkbox at all
        // (`:143`), so composing it unconditionally could hand back a "Control Bar" that no
        // transport control lives in — and `findTransportButton` would then search only that and
        // return nil, where the old scan would have found the working container further down.
        //
        // Raised by review as a real regression path, not a hypothetical: an accessor that answers
        // by NAME and a caller that needs a CAPABILITY are not the same question, and this is the
        // seam where a rename becomes a silent failure. Validating here keeps the discriminated
        // accessor's benefit — an unambiguous answer when it has one — without letting a labelled
        // shell shadow a container that actually works.
        // NOT `looksLikeTransportContainer`: its first branch matches on METADATA, so the shell
        // above — described "Control Bar", holding nothing — satisfies it. That was the first
        // attempt at this fix and the new test caught it returning the shell anyway. Name and
        // capability are different questions and this caller needs the second one.
        if let identified = getControlBar(runtime: runtime),
           !transportControlKeywordHits(in: identified, runtime: runtime.ax).isEmpty {
            return identified
        }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax)
        let survivors = transportContainerCandidates(among: groups, runtime: runtime)
        if let candidate = survivors.first {
            // Reached only when `getControlBar` could NOT identify one, so more than one survivor
            // here means both the discriminated route and the keyword scan failed to resolve.
            //
            // The keyword scan over-accepts, and the cause is measured. It takes any container
            // holding two or more transport-keyword controls, and the arrange area qualifies on
            // substrings of labels that are not transport controls at all: "play" inside "Catch
            // Playhead", "loop" inside "Show/Hide Live Loops Grid". (The cause first written here
            // was "a track header holds a record-arm checkbox"; instrumenting the predicate
            // disproved it — `record` never matched.) The false-friend guard rejects those, and
            // survivors went 4 -> 2 on a one-track project. Measured again 2026-08-28 on this
            // machine: five survivors, and adding three tracks moved `gathered` by three while
            // leaving `survivors` at five — so the count is not a function of project size, and
            // what accounts for four versus five is not established.
            //
            // Whatever that count is, tree order was the wrong way to reduce it.
            //
            // Log lines below go to stderr, which the live-evidence harness discards
            // (`Scripts/livekit/evidence.py` runs the server with `stderr=DEVNULL`). They reach an
            // operator reading the server log and do NOT reach the evidence document — said rather
            // than left implied, because a line that cannot reach the channel the gate reads is not
            // "making it visible" to the gate.
            _ = candidate
            let finalists = transportContainerFinalists(among: survivors, runtime: runtime.ax)
            if finalists.count == 1 {
                return finalists[0]
            }
            // Refusing, not choosing. Reaching here means the discriminated route failed AND the
            // narrowed keyword scan cannot tell its candidates apart, which is a tree this code has
            // never been measured against. Every caller writes `?? …` or guards on nil, and
            // ADR-007's version policy is explicit that an unknown signature fails closed rather
            // than guessing — returning the first in tree order is the wrong-target behaviour that
            // policy names.
            Log.info(
                "getTransportBar: getControlBar did not identify one, \(survivors.count) groups "
                    + "matched the keyword scan and \(finalists.count) survived narrowing; "
                    + "refusing rather than picking one",
                subsystem: "ax"
            )
            return nil
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

    /// The keyword scan's survivors, reduced by the discriminators `getControlBar` already applies.
    ///
    /// This answers the contract question the site deferred — whether "transport bar" and "control
    /// bar" name the same thing — and the evidence answered it rather than a preference:
    /// `getTransportBar` tries `getControlBar()` FIRST and every caller writes one or the other;
    /// `--probe-selection-census` measures both paths returning the SAME element on a live tree;
    /// and the group Logic labels is `Control Bar` / `컨트롤 막대`. They are one thing, so the scan
    /// narrows the way the discriminated route does instead of choosing by tree order.
    ///
    /// Split out for the reason the other predicates were: the census must call the same reduction
    /// the product runs, not a copy that can drift from it. A returned count other than one is what
    /// the site refuses on, so this is also the number worth measuring.
    /// The atlas selector for the control bar, by name.
    ///
    /// `.exactStrict` because that is what `getControlBar` uses: a group described exactly
    /// `Control Bar` / `컨트롤 막대` / `コントロールバー`, not one whose description merely contains
    /// it. A containment match would let `Hide Control Bar` be taken for the bar — the same
    /// false-friend class the keyword scan already fails on.
    ///
    /// Identity only. Whether the named bar actually HOLDS a transport control is a separate
    /// question, and `transportContainerFinalists` asks it separately.
    static let controlBarSelector = SemanticSelector(
        id: .controlBar,
        requiredRole: kAXGroupRole as String,
        allowedSubroles: [],
        titleAliases: [:],
        ancestorConstraints: [],
        attributePredicates: [
            .attributes([kAXDescriptionAttribute as String],
                        anyOf: AXLocalePolicy.controlBarGroupLabel.labels, mode: .exactStrict),
        ],
        geometryHint: nil,
        minimumConfidence: 0.6,
        ambiguityPolicy: .failClosed
    )

    static func transportContainerFinalists(
        among survivors: [AXUIElement],
        runtime: AXHelpers.Runtime = .production
    ) -> [AXUIElement] {
        if survivors.count <= 1 { return survivors }

        // Fourth atlas adoption, and a PARTIAL one — the limit is worth stating rather than working
        // around.
        //
        // This reduction has two discriminators. The label is an identity question and resolves
        // through the atlas below. The capability test is not: `transportControlKeywordHits`
        // searches the group's DESCENDANTS for transport controls, and ADR-007's evidence model is
        // about an element and its ANCESTORS — identifier, role, ancestor chain, attributes, title,
        // value, geometry. A subtree property is not in it.
        //
        // It could have been smuggled in as a synthetic attribute. It is not, because the site
        // already says why the two are separate: "Name and capability are different questions and
        // this caller needs the second one." Identity goes through the selector; capability stays
        // its own step.
        func labelled(_ pool: [AXUIElement]) -> [AXUIElement] {
            pool.filter { group in
                let candidate = AXResolvableCandidate.make(from: group, runtime: runtime)
                return resolve(controlBarSelector, in: [candidate], locale: "any") == .exact(index: 0)
            }
        }

        // CAPABILITY BEFORE NAME, and the order is load-bearing. The site's first branch already
        // says why — "Name and capability are different questions and this caller needs the
        // second one" — and #628 measured the shape that makes it concrete: a group described
        // `Control Bar` holding NOTHING, beside one that works. Narrowing by label first picks the
        // shell, which is the regression `Issue628TransportAmbiguityTests` exists to catch, and it
        // caught this function's first draft doing exactly that.
        //
        // Capability is `transportControlKeywordHits`, the SAME test the first branch validates
        // `getControlBar` with — not `getControlBar`'s own "holds a checkbox", which was this
        // function's second draft and which the same test also caught: it describes the real
        // Logic bar but not a container whose transport controls are buttons.
        let withControls = survivors.filter { group in
            !transportControlKeywordHits(in: group, runtime: runtime).isEmpty
        }
        if withControls.count == 1 { return withControls }
        if withControls.count > 1 {
            // Several bars hold a control; now the name is the discriminator that is left.
            let named = labelled(withControls)
            return named.count == 1 ? named : (named.isEmpty ? withControls : named)
        }

        // Nothing holds a control. A lone group that at least names itself is still more than tree
        // order — the same last resort `getControlBar` takes before giving up.
        let named = labelled(survivors)
        return named.count == 1 ? named : []
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
