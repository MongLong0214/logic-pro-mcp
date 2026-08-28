import Foundation
import Testing
@testable import LogicProMCP

@Suite("SelectorAtlasTests")
struct SelectorAtlasTests {
    @Test func uniqueMatchIsMutationSafe() {
        let selector = playSelector()
        let candidates = [candidate(identifier: "play-control", role: "AXButton", title: "Play")]

        let resolution = resolve(selector, in: candidates, locale: "en")

        #expect(resolution == .exact(index: 0))
        #expect(canMutate(resolution))
    }

    @Test func duplicateMatchesFailClosedWithoutChoosingFirst() {
        let selector = SemanticSelector(
            id: .transportPlayButton,
            requiredRole: "AXButton",
            allowedSubroles: [],
            titleAliases: ["en": ["Play"]],
            ancestorConstraints: [],
            attributePredicates: [],
            geometryHint: nil,
            minimumConfidence: 0.25,
            ambiguityPolicy: .failClosed
        )
        let duplicate = candidate(identifier: nil, role: "AXButton", title: "Play")

        let resolution = resolve(selector, in: [duplicate, duplicate], locale: "en")

        #expect(resolution == .ambiguous(indices: [0, 1]))
        #expect(!canMutate(resolution))
    }

    @Test func noMatchFailsClosed() {
        let resolution = resolve(
            playSelector(),
            in: [candidate(identifier: nil, role: "AXSlider", title: "Volume")],
            locale: "en"
        )

        #expect(resolution == .notFound)
        #expect(!canMutate(resolution))
    }

    @Test func unsupportedSignatureFailsClosed() {
        let resolution = resolve(
            playSelector(),
            in: [candidate(identifier: "play-control", role: "", title: "Play")],
            locale: "en"
        )

        #expect(resolution == .unsupportedSignature)
        #expect(!canMutate(resolution))
    }

    @Test func identifierEvidenceOutranksGeometry() {
        let selector = playSelector(geometryHint: GeometryHint(x: 10, y: 10, width: 20, height: 20))
        let candidates = [
            candidate(identifier: "play-control", role: "AXButton", title: nil),
            candidate(
                identifier: nil,
                role: "AXButton",
                title: nil,
                geometry: GeometryHint(x: 10, y: 10, width: 20, height: 20)
            ),
        ]

        #expect(confidence(of: candidates[0], against: selector) > confidence(of: candidates[1], against: selector))
        #expect(resolve(selector, in: candidates, locale: "en") == .exact(index: 0))
    }

    @Test func geometryAloneCannotReachHighConfidence() {
        let selector = SemanticSelector(
            id: .mixerStripVolumeFader,
            requiredRole: "AXSlider",
            allowedSubroles: [],
            titleAliases: [:],
            ancestorConstraints: [],
            attributePredicates: [],
            geometryHint: GeometryHint(x: 0, y: 0, width: 10, height: 100),
            minimumConfidence: 0.75,
            ambiguityPolicy: .failClosed
        )
        let geometryOnly = candidate(
            identifier: nil,
            role: "AXSlider",
            title: nil,
            geometry: GeometryHint(x: 0, y: 0, width: 10, height: 100)
        )

        #expect(confidence(of: geometryOnly, against: selector) < selector.minimumConfidence)
        #expect(resolve(selector, in: [geometryOnly], locale: "en") == .notFound)
    }

    @Test func confidenceDropAndMissingSelectorsReportAffectedOperations() {
        let changed = drift(
            previous: [.mixerStripVolumeFader: 0.95],
            current: [.mixerStripVolumeFader: 0.40],
            roleChanges: [.mixerStripVolumeFader: ["AXSlider→AXGroup"]]
        )
        let missing = drift(
            previous: [.transportPlayButton: 0.95],
            current: [:],
            roleChanges: [:]
        )

        #expect(changed == [
            SelectorDrift(
                selectorID: .mixerStripVolumeFader,
                status: .changed,
                previousConfidence: 0.95,
                currentConfidence: 0.40,
                changedRoles: ["AXSlider→AXGroup"],
                affectedOperations: [.mixerSetVolume]
            ),
        ])
        #expect(missing.first?.status == .missing)
        #expect(missing.first?.affectedOperations == [.transportPlay, .transportStop])
    }

    @Test func qualificationReusePolicyFailsClosedOnUnsafeDrift() {
        let stable = makeDrift(status: .stable, previous: 0.95, current: 0.94)
        let minor = makeDrift(status: .minorDrift, previous: 0.95, current: 0.82)
        let changed = makeDrift(status: .changed, previous: 0.95, current: 0.50)
        let unknown = makeDrift(status: .missing, previous: 0.95, current: 0)

        #expect(policy(for: stable) == .reuseFull)
        #expect(policy(for: minor) == .readOnlyOnly)
        #expect(policy(for: changed) == .failClosedMutation)
        #expect(policy(for: unknown) == .failClosedMutation)
    }

    @Test func fingerprintRoundTripsWithoutNameFields() throws {
        let fingerprint = UIFingerprint(
            logicVariant: "creator",
            logicVersion: "11.2",
            locale: "ko",
            windowType: "main",
            viewMode: "mixer",
            sanitizedHierarchyHash: "sha256:abc123"
        )
        let data = try JSONEncoder().encode(fingerprint)
        let decoded = try JSONDecoder().decode(UIFingerprint.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(decoded == fingerprint)
        #expect(Set(object.keys) == [
            "logicVariant",
            "logicVersion",
            "locale",
            "windowType",
            "viewMode",
            "sanitizedHierarchyHash",
        ])
    }

    @Test func selectorIDsAreCompleteAndFeatureFlagDefaultsOff() {
        // The six leading cases were added when the first production adoptions landed. Until then
        // each borrowed an ill-fitting ID — the header pan slider was filed as
        // `mixerStripVolumeFader` — and `UIDriftReport` keys its affected-operations map on this
        // enum, so a pan drift was reported as endangering `mixer.set_volume`.
        #expect(SelectorID.allCases == [
            .trackHeaderPanControl,
            .trackHeaderVolumeFader,
            .trackHeaderMuteToggle,
            .trackHeaderSoloToggle,
            .trackHeaderArmToggle,
            .controlBar,
            .transportPlayButton,
            .trackHeaderNameField,
            .mixerStripVolumeFader,
            .mixerStripSendSlot,
            .pluginWindowTitle,
            .pluginParameterControl,
            .projectSaveFilenameField,
        ])

        let key = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr007SelectorAtlas)
    }

    private func playSelector(geometryHint: GeometryHint? = nil) -> SemanticSelector {
        SemanticSelector(
            id: .transportPlayButton,
            requiredRole: "AXButton",
            allowedSubroles: [],
            titleAliases: ["en": ["Play"], "ko": ["재생"]],
            ancestorConstraints: [],
            attributePredicates: [.axIdentifier("play-control")],
            geometryHint: geometryHint,
            minimumConfidence: 0.75,
            ambiguityPolicy: .failClosed
        )
    }

    private func candidate(
        identifier: String?,
        role: String,
        title: String?,
        geometry: GeometryHint? = nil
    ) -> ResolvableCandidate {
        ResolvableCandidate(
            axIdentifier: identifier,
            role: role,
            subrole: nil,
            title: title,
            ancestors: [],
            attributes: [:],
            valueSignature: nil,
            geometry: geometry
        )
    }

    private func makeDrift(
        status: SelectorDriftStatus,
        previous: Double,
        current: Double
    ) -> SelectorDrift {
        SelectorDrift(
            selectorID: .transportPlayButton,
            status: status,
            previousConfidence: previous,
            currentConfidence: current,
            changedRoles: [],
            affectedOperations: [.transportPlay, .transportStop]
        )
    }
}

/// #290 — the scoring is a ratio over the evidence a selector ASKED FOR, not a fixed budget.
///
/// This suite recorded the defect before it recorded the fix, and the numbers below are the same
/// measurement read the other way round.
///
/// The budget awarded 0.55 of a possible 1.0 for an exact `AXIdentifier`, so an element without one
/// could never exceed 0.45 however much else it matched. Measured 2026-08-28 on Logic 12.x: the
/// track-header sliders expose no `AXIdentifier` at all — the attribute is absent from the element,
/// not empty — and the pan slider has no `AXTitle` either, because its name lives in `AXHelp`. A
/// slider satisfying every predicate its selector named scored **0.40**, and an ordinary-looking
/// `minimumConfidence: 0.6` refused it.
///
/// Lowering thresholds to 0.4 instead would have left the tiers decorative and published a
/// confidence nothing measures — the shape removed from three other places the same day.
@Suite("Issue290ScoringNormalisesOverRequestedEvidence")
struct Issue290ScoringNormalisesOverRequestedEvidenceTests {

    /// Transcribed from the live tree, not invented: role, absent identifier, absent title, the
    /// help string that carries the name, and the value range that separates pan from volume.
    private var measuredPanSlider: ResolvableCandidate {
        ResolvableCandidate(
            axIdentifier: nil,
            role: "AXSlider",
            subrole: nil,
            title: nil,
            ancestors: ["AXLayoutItem", "AXGroup", "AXWindow"],
            attributes: ["AXHelp": "패닝 노브 및 밸런스 노브. 트랙 신호를 스테레오 필드에 위치하려면 수직으로 드래그합니다."],
            valueSignature: "0...127",
            geometry: nil
        )
    }

    private func selector(
        _ predicates: [AttributePredicate],
        ancestors: [AncestorConstraint] = [AncestorConstraint(role: "AXLayoutItem")],
        geometry: GeometryHint? = nil,
        minimumConfidence: Double = 0.6
    ) -> SemanticSelector {
        SemanticSelector(
            id: .mixerStripVolumeFader, requiredRole: "AXSlider", allowedSubroles: [],
            titleAliases: [:], ancestorConstraints: ancestors,
            attributePredicates: predicates, geometryHint: geometry,
            minimumConfidence: minimumConfidence, ambiguityPolicy: .failClosed
        )
    }

    @Test("an element with no identifier resolves when it matches what the selector asked for")
    func normalisedOverRequestedEvidence() {
        // The case the budget refused at 0.40. Nothing about the element changed — the selector no
        // longer has an identifier in its denominator, because it never asked for one.
        let s = selector([
            .attributes(["AXHelp"], anyOf: ["밸런스"], mode: .contains),
            .valueSignature("0...127"),
        ])
        #expect(confidence(of: measuredPanSlider, against: s) == 1)
        #expect(resolve(s, in: [measuredPanSlider], locale: "ko") == .exact(index: 0))
    }

    @Test("asking for an identifier the element lacks still scores low")
    func askingForAMissingIdentifierStillCosts() {
        // The strictness that had to survive. A ratio could have made everything resolve; it does
        // not, because a selector that names an identifier and does not get one has lost its
        // strongest evidence and the denominator says so.
        let s = selector([
            .axIdentifier("pan-slider"),
            .attributes(["AXHelp"], anyOf: ["밸런스"], mode: .contains),
            .valueSignature("0...127"),
        ])
        let score = confidence(of: measuredPanSlider, against: s)
        #expect(score < 0.6, "scored \(score); a missing identifier cost nothing")
        #expect(resolve(s, in: [measuredPanSlider], locale: "ko") == .notFound)
    }

    @Test("an identifier still dominates when it is there")
    func identifierStillDominates() {
        // ADR-007's evidence priority is unchanged: the identifier is the heaviest single tier.
        let withID = ResolvableCandidate(
            axIdentifier: "pan-slider", role: "AXSlider", subrole: nil, title: nil,
            ancestors: measuredPanSlider.ancestors, attributes: [:], valueSignature: nil, geometry: nil
        )
        let s = selector([.axIdentifier("pan-slider")], ancestors: [])
        #expect(resolve(s, in: [withID], locale: "ko") == .exact(index: 0))
    }

    @Test("role alone cannot identify anything")
    func roleAloneIsCapped() {
        // Under a ratio a selector naming ONLY a role matches everything it asked for and would
        // otherwise score 1.0. "It is a slider" is not an identification.
        #expect(confidence(of: measuredPanSlider, against: selector([], ancestors: [])) <= 0.49)
    }

    @Test("geometry alone cannot produce high confidence")
    func geometryAloneIsCapped() {
        // ADR-007 acceptance criterion, preserved through the rewrite rather than assumed.
        let hint = GeometryHint(x: 1, y: 2, width: 3, height: 4)
        let positioned = ResolvableCandidate(
            axIdentifier: nil, role: "AXSlider", subrole: nil, title: nil,
            ancestors: [], attributes: [:], valueSignature: nil, geometry: hint
        )
        #expect(confidence(of: positioned, against: selector([], ancestors: [], geometry: hint)) <= 0.49)
    }

    @Test("containment is what equality could not express")
    func containmentIsWhatWasMissing() {
        let help = "패닝 노브 및 밸런스 노브. 트랙 신호를 스테레오 필드에 위치하려면 수직으로 드래그합니다."
        let byEquality = selector([.attributes(["AXHelp"], anyOf: [help], mode: .exact)])
        let byContainment = selector([.attributes(["AXHelp"], anyOf: ["밸런스"], mode: .contains)])
        #expect(confidence(of: measuredPanSlider, against: byEquality) == 1)
        #expect(confidence(of: measuredPanSlider, against: byContainment) == 1)

        // The difference is what happens when the sentence changes — a Logic update, another
        // locale. Equality breaks; containment does not. An equality predicate on a localized
        // sentence cannot be written for a locale nobody has measured.
        let reworded = ResolvableCandidate(
            axIdentifier: nil, role: "AXSlider", subrole: nil, title: nil,
            ancestors: measuredPanSlider.ancestors,
            attributes: ["AXHelp": "밸런스 노브입니다."],
            valueSignature: measuredPanSlider.valueSignature, geometry: nil
        )
        #expect(confidence(of: reworded, against: byEquality) < 0.6)
        #expect(confidence(of: reworded, against: byContainment) == 1)
    }
}

/// #290 — the affected-operations map is a second copy of a relationship, and this is what keeps
/// it honest.
///
/// `UIDriftReport` answers "which operations does this selector's drift put at risk" from a
/// hand-maintained dictionary. Nothing checked it. Four selectors adopted in production had to
/// borrow ill-fitting IDs until the enum gained cases for them — the header pan slider was filed as
/// `mixerStripVolumeFader` — so a pan drift was reported as endangering `mixer.set_volume`. That is
/// a wrong answer delivered confidently, which is the only kind this map can produce.
@Suite("SelectorAtlasOperationMap")
struct SelectorAtlasOperationMapTests {

    @Test("every selector has a decision recorded, including an empty one")
    func everySelectorIsMapped() {
        // A missing key and a deliberate empty list are indistinguishable at the call site, which
        // reads `operationsBySelector[id] ?? []`. So an ID added without a decision would silently
        // report that its drift affects nothing.
        let mapped = drift(
            previous: Dictionary(uniqueKeysWithValues: SelectorID.allCases.map { ($0, 0.9) }),
            current: Dictionary(uniqueKeysWithValues: SelectorID.allCases.map { ($0, 0.9) }),
            roleChanges: [:]
        )
        #expect(mapped.count == SelectorID.allCases.count)
        let unmapped = mapped.filter { $0.affectedOperations.isEmpty }.map(\.selectorID)
        // `mixerStripSendSlot` is the one deliberate empty: no send operation is registered.
        #expect(unmapped == [.mixerStripSendSlot], "unmapped: \(unmapped)")
    }

    @Test("every operation the map names is registered")
    func mappedOperationsExist() {
        // The failure this catches is a rename or a removal in the registry leaving this map
        // pointing at an operation nobody serves — a drift report that names impact on something
        // that cannot be impacted.
        let registered = Set(OperationRegistry.specs.map(\.id))
        let named = Set(drift(
            previous: Dictionary(uniqueKeysWithValues: SelectorID.allCases.map { ($0, 0.9) }),
            current: Dictionary(uniqueKeysWithValues: SelectorID.allCases.map { ($0, 0.5) }),
            roleChanges: [:]
        ).flatMap(\.affectedOperations))
        #expect(!named.isEmpty)
        #expect(named.isSubset(of: registered),
                "not registered: \(named.subtracting(registered).map(\.rawValue).sorted())")
    }

    @Test("the adopted selectors map to the operations that actually drive them")
    func adoptedSelectorsMapToTheirOwnOperations() {
        // The two checks above do NOT catch the defect this suite was written for. Mapping the pan
        // slider to `mixer.set_volume` passes both — every ID has an entry, and `mixerSetVolume` is
        // registered — which is a check that cannot see its own subject. Measured by mutation:
        // re-pointing `.trackHeaderPanControl` at `.mixerSetVolume` left the suite green.
        //
        // So the six selectors with production consumers are pinned. It is a second copy of the
        // mapping and that is the point: changing one now requires changing the other, which is how
        // a hand-maintained relationship is kept from drifting silently.
        let reported = Dictionary(uniqueKeysWithValues: drift(
            previous: Dictionary(uniqueKeysWithValues: SelectorID.allCases.map { ($0, 0.9) }),
            current: Dictionary(uniqueKeysWithValues: SelectorID.allCases.map { ($0, 0.5) }),
            roleChanges: [:]
        ).map { ($0.selectorID, Set($0.affectedOperations)) })

        #expect(reported[.trackHeaderPanControl] == [.mixerSetPan])
        #expect(reported[.trackHeaderVolumeFader] == [.mixerSetVolume])
        #expect(reported[.trackHeaderMuteToggle] == [.tracksMute])
        #expect(reported[.trackHeaderSoloToggle] == [.tracksSolo])
        #expect(reported[.trackHeaderArmToggle] == [.tracksArm, .tracksArmOnly])
        #expect(reported[.controlBar] == [.transportPlay, .transportStop])
    }

    @Test("the adopted selectors carry the identity they actually select")
    func adoptedSelectorsAreHonestlyIdentified() {
        // The defect this suite exists for, asserted directly at the four production selectors.
        #expect(AXLogicProElements.headerPanSelector.id == .trackHeaderPanControl)
        #expect(AXLogicProElements.volumeFaderSelector.id == .trackHeaderVolumeFader)
        #expect(AXLogicProElements.controlBarSelector.id == .controlBar)
        #expect(AXLogicProElements.toggleSelector(
            labels: AXLocalePolicy.trackMuteButton.labels).id == .trackHeaderMuteToggle)
        #expect(AXLogicProElements.toggleSelector(
            labels: AXLocalePolicy.trackSoloButton.labels).id == .trackHeaderSoloToggle)
        #expect(AXLogicProElements.toggleSelector(
            labels: AXLocalePolicy.trackRecordEnableCheckbox.labels).id == .trackHeaderArmToggle)
    }
}
