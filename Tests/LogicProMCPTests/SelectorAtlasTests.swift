@preconcurrency import ApplicationServices
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

/// #290 — a fixture cannot carry a user's project, track or plugin name.
///
/// The criterion is "fixtures contain no user project/track/plugin names", and the way to satisfy it
/// is not to scrub: a scrubber has to enumerate what to remove, and the thing it has never heard of
/// is exactly the thing a user named. `AXSnapshot` is an ALLOWLIST — a free-text value survives only
/// if it appears in `AXLocalePolicy`, and everything else is reduced to its shape.
@Suite("Issue290SnapshotRedaction")
struct Issue290SnapshotRedactionTests {

    @Test("a recognised label survives verbatim, including its case, inside a chrome role")
    func recognisedLabelsSurvive() {
        // Verbatim and case-preserved, because selectors match `.exactStrict` — a snapshot that
        // lower-cased everything would show a tree no selector could be tested against.
        //
        // Inside a chrome role. These three used to be asserted with no role at all, which is the
        // caller declining to say where the string came from — and the answer to that question can
        // no longer be "verbatim", because a track a user named `Audio` walked out of an
        // `AXTextField` on exactly that path.
        #expect(AXSnapshot.redact("볼륨", role: kAXSliderRole as String) == "볼륨")
        #expect(AXSnapshot.redact("Control Bar", role: kAXCheckBoxRole as String) == "Control Bar")
        #expect(AXSnapshot.redact("컨트롤 막대", role: kAXSliderRole as String) == "컨트롤 막대")

        // And an `AXGroup` is not a chrome role, which has a cost this suite states rather than
        // hides: the control bar is identified BY its group description, so shaping group text
        // means no committed baseline can score `.controlBar`. `AtlasDiff.uncovered` reports that
        // instead of letting the verdict read the silence as agreement.
        #expect(AXSnapshot.redact("컨트롤 막대", role: kAXGroupRole as String)
                    == "len:6 non-latin+space")
    }

    @Test("names the product does not recognise are reduced to a shape")
    func userNamesAreReducedToShape() throws {
        // Every one of these is a plausible thing a user types, and none is in any policy set.
        for name in ["Absolute Zero", "Vintage EQ", "무제 30", "lead vox DOUBLE 2", "Song.logicx"] {
            let redacted = try #require(AXSnapshot.redact(name))
            #expect(redacted != name, "\(name) survived verbatim")
            #expect(redacted.hasPrefix("len:"), "\(name) -> \(redacted)")
        }
    }

    @Test("the shape says enough to notice a change and not enough to read a name")
    func shapeIsInformativeButNotRevealing() {
        let shape = AXSnapshot.shape(of: "Absolute Zero")
        #expect(shape.contains("len:13"))
        #expect(shape.contains("latin"))
        #expect(!shape.lowercased().contains("absolute"))
        #expect(!shape.lowercased().contains("zero"))
        // A different name of the SAME shape is indistinguishable, which is the property that makes
        // this safe rather than a weak cipher. Both are thirteen latin-and-space characters — the
        // first version of this case compared a 13 against a 14 and failed, which is the shape doing
        // its job: length is information it deliberately keeps.
        #expect(AXSnapshot.shape(of: "Absolute Zero") == AXSnapshot.shape(of: "Terrible Noiz"))
    }

    @Test("a prefix is only conceded where Logic actually appends state")
    func prefixAllowanceIsScopedToItsPhenomenon() throws {
        // Measured on a real capture: five `AXTextField` descriptions came out as `오디오…` because
        // `오디오` is a variant in two policy sets and the tracks were named `오디오 1`, `오디오 2`.
        // A track name's leading token is part of a track name, so the fixture was leaking one.
        //
        // The concession exists for checkbox descriptions that carry state. It belongs there.
        // Bound with `try #require`, not compared against a boolean literal — that comparison is
        // always-pass on this toolchain, and the first version of this case used it. Mutation-tested
        // afterwards: restoring the prefix allowance everywhere left the suite GREEN, which is how
        // a dead assertion looks from the outside.
        let inATextField = try #require(
            AXSnapshot.redact("오디오 1", role: kAXTextFieldRole as String))
        #expect(inATextField.hasPrefix("len:"), "a track name kept its recognised prefix")

        let inACheckbox = try #require(
            AXSnapshot.redact("음소거, 켬", role: kAXCheckBoxRole as String))
        #expect(inACheckbox.hasPrefix("음소거"), "the state-suffix concession stopped working")

        // Without a role at all, no concession — the caller has not established the phenomenon.
        let roleless = try #require(AXSnapshot.redact("오디오 1"))
        #expect(roleless.hasPrefix("len:"))

        // An exact match is NOT safe outside a chrome role, and this case used to assert the
        // opposite. `redact("볼륨", role: textField) == "볼륨"` encoded the reasoning that the value
        // IS a label the product knows — which is a statement about the string and not about where
        // it came from. `audio` is declared in two policy sets, so a track a user named `Audio`
        // walked out of an `AXTextField` intact. The role gate now comes first.
        #expect(AXSnapshot.redact("볼륨", role: kAXTextFieldRole as String) == "len:2 non-latin")
        #expect(AXSnapshot.redact("Audio", role: kAXTextFieldRole as String) == "len:5 latin")
        // And it still survives where the role says the string is Logic's own.
        #expect(AXSnapshot.redact("볼륨", role: kAXSliderRole as String) == "볼륨")

        // An identifier never gets the concession, whatever carries it. A slider is a chrome role,
        // so before `redactIdentifier` existed this returned the labels found INSIDE the value —
        // `user-named-thing` contains `name`, and the fixture kept it.
        let identifier = try #require(AXSnapshot.redactIdentifier("user-named-thing"))
        #expect(identifier.hasPrefix("len:"), "an identifier kept \(identifier)")
    }

    /// The three committed baselines, by the name they are filed under.
    static let committedFixtures = [
        "logic-12.x-desktop-ko-track-headers.json",
        "logic-12.x-desktop-en-track-headers.json",
        "logic-12.x-desktop-ko-window.json",
    ]

    static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AX/\(name)")
    }

    @Test("no committed baseline carries a name from the project it was captured on",
          arguments: Issue290SnapshotRedactionTests.committedFixtures)
    func committedFixtureIsClean(_ name: String) throws {
        // The criterion at the artifact, not the function — and at EVERY artifact, because a rule
        // that holds for the file someone remembered to check is not a rule.
        //
        // All three were captured on `lpm-606-warm`, whose tracks are named `Audio 1` and whose
        // channel strip shows `Absolute Zero` and `Stereo Out`.
        let text = try String(contentsOf: Self.fixtureURL(name), encoding: .utf8)
        for secret in ["lpm-606-warm", "Absolute Zero", "Absolute", "Stereo Out", "Audio 1"] {
            #expect(!text.contains(secret), "\(secret) is in \(name)")
        }

        // A bare token is NOT on that list, and the reason is worth stating rather than quietly
        // dropping: `오디오` and `audio` appear inside Logic's own help sentences about
        // record-enabling an audio track. The criterion is "no user project/track/plugin NAMES",
        // not "no token that also occurs in one".
        //
        // So the structural property is asserted too, and it is stronger than any blacklist: a name
        // lives in a text field, a group description or a layout row, and every one of those in
        // these captures is a shape.
        let document = try JSONDecoder().decode(AXSnapshot.Document.self, from: Data(text.utf8))
        let nameBearing: Set<String> = [
            kAXTextFieldRole as String, kAXGroupRole as String, kAXLayoutItemRole as String,
        ]
        var carried: [String] = []
        var shaped = 0
        func walk(_ node: AXSnapshot.Node) {
            if nameBearing.contains(node.role) {
                for value in [node.description, node.help, node.identifier].compactMap({ $0 }) {
                    carried.append(value)
                    if value.hasPrefix("len:") { shaped += 1 }
                }
            }
            node.children.forEach(walk)
        }
        walk(document.root)
        #expect(!carried.isEmpty, "nothing name-bearing in \(name) — nothing was tested")
        #expect(shaped == carried.count,
                "\(name) kept \(carried.filter { !$0.hasPrefix("len:") })")

        // And it is a real capture, not an empty file that trivially contains no names.
        #expect(text.count > 5_000, "\(name) is too small to be a capture")
    }

    @Test("a label with a state suffix keeps its recognised prefix and loses the rest")
    func statePrefixesAreKept() throws {
        // Logic appends state to some checkbox descriptions and `.prefix` is a mode selectors use,
        // so `음소거, 켬` must not read as an unrecognised string — but the suffix is still not a
        // label the product knows, and it does not survive intact.
        let redacted = try #require(AXSnapshot.redact("음소거, 켬", role: kAXCheckBoxRole as String))
        #expect(redacted.hasPrefix("음소거"), "\(redacted)")
        #expect(redacted != "음소거, 켬")
    }

    @Test("a captured tree carries no unrecognised free text anywhere in it")
    func capturedTreeIsClean() throws {
        // The property at the level it matters: not one value, a whole tree. The names below are in
        // description, help and identifier, at two depths.
        let b = FakeAXRuntimeBuilder()
        let root = b.element(9000)
        let child = b.element(9001)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(root, kAXDescriptionAttribute as String, "My Secret Project")
        b.setAttribute(child, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(child, kAXDescriptionAttribute as String, "볼륨")
        b.setAttribute(child, kAXHelpAttribute as String, "Lead Vocal Double")
        b.setAttribute(child, kAXIdentifierAttribute as String, "user-named-thing")
        b.setChildren(root, [child])

        let node = AXSnapshot.capture(root, runtime: b.makeAXRuntime())
        let encoded = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)

        for secret in ["My Secret Project", "Lead Vocal Double", "user-named-thing"] {
            #expect(!encoded.contains(secret), "\(secret) reached the snapshot")
        }
        // And the recognised one did survive, or the snapshot would be useless.
        #expect(encoded.contains("볼륨"))
    }
}

/// #290 — the atlas diff, which is the last criterion with no environment constraint.
///
/// `UIDriftReport` takes `[SelectorID: Double]` and nothing produced those numbers, so it could not
/// be called from anywhere — the same shape as the resolver having no adapter. `AtlasDiff` scores a
/// baseline against the selectors actually in production, so a diff is two snapshots and needs no
/// Logic on the machine. That matters: a qualification step that required the application open
/// would not run where qualification runs.
@Suite("Issue290AtlasDiff")
struct Issue290AtlasDiffTests {

    private func load(_ name: String) throws -> AXSnapshot.Document {
        try JSONDecoder().decode(
            AXSnapshot.Document.self,
            from: Data(contentsOf: Issue290SnapshotRedactionTests.fixtureURL(name)))
    }

    private func baseline() throws -> AXSnapshot.Document {
        try load("logic-12.x-desktop-ko-track-headers.json")
    }

    /// A track-header rail does not contain the control bar, so a pair of them leaves `.controlBar`
    /// unmeasured. That is what `uncovered` is for, and this is the second baseline that closes it.
    private func windowBaseline() throws -> AXSnapshot.Document {
        try load("logic-12.x-desktop-ko-window.json")
    }

    @Test("the committed baseline scores the selectors that resolve against it")
    func baselineScoresAdoptedSelectors() throws {
        // If it did not, every diff below would compare two empty dictionaries and pass while
        // measuring nothing — the vacuous shape this suite has to avoid first.
        let scores = AtlasDiff.confidences(in: try baseline())
        #expect(scores[.trackHeaderPanControl] != nil, "pan scored nothing in the baseline")
        #expect(scores[.trackHeaderVolumeFader] != nil)
        #expect(scores[.trackHeaderMuteToggle] != nil)
        #expect(scores[.trackHeaderSoloToggle] != nil)
        #expect(scores[.trackHeaderArmToggle] != nil)
        for (id, value) in scores {
            #expect(value >= 0.6, "\(id) scored \(value), below the selectors' own threshold")
        }
    }

    @Test("a baseline against itself is stable, and reusable only once every selector is covered")
    func identicalBaselinesAreStable() throws {
        let rail = try baseline()
        let drifts = AtlasDiff.between(baseline: rail, current: rail)
        #expect(!drifts.isEmpty)
        #expect(drifts.allSatisfy { $0.status == .stable })

        // A rail on its own does NOT earn full reuse, and this is the case that used to say it did.
        // Nothing in a track-header capture contradicts the control bar, so a verdict read off the
        // drift list alone called transport qualified on the strength of never having looked at it.
        let railOnly = AtlasDiff.uncovered(baseline: rail, current: rail)
        #expect(railOnly == [.controlBar], "the rail's coverage gap moved: \(railOnly)")
        #expect(AtlasDiff.verdict(for: drifts, uncovered: railOnly) == .failClosedMutation)

        // The window baseline does not close it either, and that is a measured fact rather than an
        // oversight: the control bar is identified by an `AXGroup` description, groups can carry a
        // plugin name, and the redaction shapes them. So `.controlBar` is unmeasured by every
        // committed baseline, and until one covers it no pair of them can qualify a transport
        // mutation. Naming the gap is the point — the previous verdict called it qualified.
        let window = try windowBaseline()
        let both = railOnly.intersection(
            AtlasDiff.uncovered(baseline: window, current: window))
        #expect(both == [.controlBar], "the coverage gap moved: \(both)")
        #expect(AtlasDiff.verdict(for: drifts, uncovered: both) == .failClosedMutation)

        // Reuse is reachable — it just takes a baseline set that covers everything, which is what
        // the empty argument stands for here.
        #expect(AtlasDiff.verdict(for: drifts, uncovered: []) == .reuseFull)
    }

    @Test("a selector that keeps its best score but loses most of its controls is drift")
    func partialLossIsDrift() throws {
        // The failure the best-score view cannot see, and the reason `coverage` exists. Logic strips
        // the volume fader from every track header but the first: the strongest evidence in the tree
        // is still a perfect match, so `confidences` is unchanged and the diff read `.stable` —
        // while `mixer.set_volume` fails on every track except one.
        let rail = try baseline()
        let units = AtlasDiff.repeatedUnits(in: rail)
        #expect(units.count >= 3, "the rail has \(units.count) rows — too few to lose most of them")

        let keptFirst = AXSnapshot.Document(
            logicVersion: rail.logicVersion, locale: rail.locale, scope: rail.scope,
            capturedFrom: rail.capturedFrom,
            root: AXSnapshot.Node(
                role: rail.root.role, subrole: rail.root.subrole,
                description: rail.root.description, help: rail.root.help,
                identifier: rail.root.identifier, valueRange: rail.root.valueRange,
                children: [units[0]] + units.dropFirst().map(Self.withoutVolume)))

        #expect(AtlasDiff.confidences(in: keptFirst)[.trackHeaderVolumeFader]
                    == AtlasDiff.confidences(in: rail)[.trackHeaderVolumeFader],
                "the best score changed, so this case is not testing what it says")

        let drifts = AtlasDiff.between(baseline: rail, current: keptFirst)
        let volume = try #require(drifts.first { $0.selectorID == .trackHeaderVolumeFader })
        #expect(volume.status == .changed, "partial loss read as \(volume.status)")
        #expect(AtlasDiff.verdict(for: drifts, uncovered: []) == .failClosedMutation)
    }

    /// Every volume label removed from one track row, and nothing else touched.
    private static func withoutVolume(_ node: AXSnapshot.Node) -> AXSnapshot.Node {
        func strip(_ value: String?) -> String? {
            guard let value else { return nil }
            return AXLocalePolicy.sliderVolumeHint.labels.contains(where: {
                value.lowercased().contains($0.lowercased())
            }) ? "len:\(value.count) redacted" : value
        }
        return AXSnapshot.Node(
            role: node.role, subrole: node.subrole,
            description: strip(node.description), help: strip(node.help),
            identifier: node.identifier, valueRange: node.valueRange,
            children: node.children.map(withoutVolume))
    }

    @Test("a selector that loses its control fails the run closed")
    func aVanishedSelectorFailsClosed() throws {
        // The failure this step exists to catch: a Logic update renames what a selector matches on,
        // and the control stops being findable. Simulated by removing the label from the tree, not
        // by editing the expected numbers.
        let doc = try baseline()
        let stripped = try JSONDecoder().decode(
            AXSnapshot.Document.self,
            from: Data(String(decoding: try JSONEncoder().encode(doc), as: UTF8.self)
                .replacingOccurrences(of: "볼륨", with: "len:2 non-latin").utf8))

        let drifts = AtlasDiff.between(baseline: doc, current: stripped)
        let volume = try #require(drifts.first { $0.selectorID == .trackHeaderVolumeFader })
        #expect(volume.status == .missing)
        #expect(volume.affectedOperations == [.mixerSetVolume])
        #expect(AtlasDiff.verdict(for: drifts, uncovered: []) == .failClosedMutation,
                "a selector that cannot find its control did not stop a mutation")
    }

    private func englishBaseline() throws -> AXSnapshot.Document {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AX/logic-12.x-desktop-en-track-headers.json")
        return try JSONDecoder().decode(AXSnapshot.Document.self, from: Data(contentsOf: url))
    }

    @Test("the same selectors resolve against a baseline captured in another language")
    func selectorsResolveAcrossLocales() throws {
        // The claim a single-locale atlas cannot make. Both fixtures are real captures from this
        // machine — Logic quit, `defaults write com.apple.logic10 AppleLanguages -array en`,
        // relaunched — so the two differ in Logic's own strings and in nothing else.
        //
        // What it caught: the rail is `트랙 헤더` in Korean and `Tracks header` in English. Not a
        // translation of the same shape — the noun that is plural in one is singular in the other,
        // and a selector written from the Korean alone would have looked for `track headers`.
        let scores = AtlasDiff.confidences(in: try englishBaseline())
        for id: SelectorID in [
            .trackHeaderPanControl, .trackHeaderVolumeFader,
            .trackHeaderMuteToggle, .trackHeaderSoloToggle, .trackHeaderArmToggle,
        ] {
            let value = try #require(scores[id], "\(id) found nothing in the English baseline")
            #expect(value >= 0.6, "\(id) scored \(value) in English, below its own threshold")
        }
    }

    @Test("a cross-locale diff is drift in Logic, not drift in the language")
    func localeChangeIsNotDrift() throws {
        // The trap this pins: diffing two locales must NOT read as a broken atlas. If it did, the
        // qualification step would fail closed on every machine that is not the one the baseline was
        // captured on — a gate that fires on its operator's language is not measuring Logic.
        let drifts = AtlasDiff.between(
            baseline: try baseline(), current: try englishBaseline())
        #expect(!drifts.isEmpty, "nothing was compared")
        let moved = drifts.filter { $0.status != .stable }
            .map { "\($0.selectorID) \($0.status)" }.joined(separator: ", ")
        #expect(AtlasDiff.verdict(for: drifts, uncovered: []) == .reuseFull,
                "changing Logic's language read as UI drift: \(moved)")
    }

    @Test("the English baseline carries no name from the project it was captured on")
    func englishFixtureIsClean() throws {
        // Same criterion as the Korean fixture, and it has to be re-measured rather than inherited:
        // this capture ran against `lpm-606-warm`, a different project with latin track names, and
        // latin text is exactly what the shape encoding compresses least.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AX/logic-12.x-desktop-en-track-headers.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("lpm-606-warm"), "the project name is in the fixture")

        let document = try JSONDecoder().decode(AXSnapshot.Document.self, from: Data(text.utf8))
        var textFields: [String] = []
        var layoutItems: [String] = []
        func walk(_ node: AXSnapshot.Node) {
            if let description = node.description {
                if node.role == kAXTextFieldRole as String { textFields.append(description) }
                if node.role == kAXLayoutItemRole as String { layoutItems.append(description) }
            }
            node.children.forEach(walk)
        }
        walk(document.root)

        // Both places a track name reaches: the field that shows it, and the row that contains it.
        #expect(!textFields.isEmpty, "no text field in the capture — nothing was tested")
        #expect(!layoutItems.isEmpty, "no track row in the capture — nothing was tested")
        for description in textFields + layoutItems {
            #expect(description.hasPrefix("len:"), "a name-bearing element kept \(description)")
        }

        // And it is a real capture of English Logic, not an empty file that trivially holds no name.
        for label in ["Mute", "Solo", "Volume", "Record Enable"] {
            #expect(text.contains(label), "\(label) is missing — this is not an English capture")
        }
        #expect(document.locale == "en")
    }

    @Test("the run verdict is the worst case, not the average")
    func verdictIsTheWorstCase() {
        // Five stable selectors and one that vanished must not average out to reusable. That is how
        // a gate stops being one.
        let stable = SelectorDrift(
            selectorID: .trackHeaderPanControl, status: .stable,
            previousConfidence: 1, currentConfidence: 1,
            changedRoles: [], affectedOperations: [.mixerSetPan])
        let gone = SelectorDrift(
            selectorID: .trackHeaderVolumeFader, status: .missing,
            previousConfidence: 1, currentConfidence: 0,
            changedRoles: [], affectedOperations: [.mixerSetVolume])
        #expect(AtlasDiff.verdict(for: [stable, stable, stable, stable, stable], uncovered: []) == .reuseFull)
        #expect(AtlasDiff.verdict(for: [stable, stable, stable, stable, gone], uncovered: []) == .failClosedMutation)
    }
}
