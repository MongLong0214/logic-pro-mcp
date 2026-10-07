@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #628: `getTransportBar` gathers groups, narrows with `looksLikeTransportContainer`, and returns
/// the first survivor. Measured on Logic 12.3 — one project, one track — **thirty-seven gathered,
/// four survive**, and two of the four are the arrange area.
///
/// The cause first written here was "a track header holds a record-arm checkbox". **That was wrong**
/// and instrumenting the predicate disproved it: `record` is not among the keywords either arrange
/// group matches. The real mechanism is substring matching on short generic words —
/// `"play" ⊂ "Catch Playhead"` and `"loop" ⊂ "Show/Hide Live Loops Grid"` — which is measured, and
/// which the false-friend guard now rejects. Survivors 4 -> 2 live.
///
/// The element returned is unchanged by this work. What changed is that the count exists as a value
/// instead of only inside an `if let`, so a tree-order choice among several can say so.
///
/// These cases assert the SPLIT and the COMPOSITION: that the candidate list's size is what a
/// caller would have to look at to know whether a choice was forced or free, and that consulting
/// `getControlBar` first cannot hand back a labelled shell in place of a container that works.
@Suite("Issue #628 — the transport scan's candidate list is a value")
struct Issue628TransportAmbiguityTests {

    @Test("the container predicate reuses the Japanese tempo field authority",
          arguments: [kAXStaticTextRole as String, kAXTextFieldRole as String])
    func japaneseTempoFieldQualifiesTheHeldContainer(role: String) throws {
        let b = FakeAXRuntimeBuilder()
        let container = b.element(904810), play = b.element(904811), tempo = b.element(904812)
        b.setAttribute(container, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(play, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(play, kAXDescriptionAttribute as String, "Play")
        b.setAttribute(tempo, kAXRoleAttribute as String, role)
        // Independent literal from the existing Tempo#mti row, not the policy under test.
        // Numeric-only value rules out the BPM, clock and multidot fallbacks; this is injected,
        // not a native Japanese container or field-provider qualification.
        b.setAttribute(tempo, kAXDescriptionAttribute as String, "テンポ")
        b.setAttribute(tempo, kAXValueAttribute as String, "128")
        b.setChildren(container, [play, tempo])

        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [container], runtime: b.makeLogicRuntime())
        #expect(candidates.count == 1)
        let held = try #require(candidates.first)
        #expect(CFEqual(held, container))
        let state = AXValueExtractors.extractTransportState(from: held, runtime: b.makeAXRuntime())
        #expect(state.tempo == 128)
    }

    @Test("legacy English and Korean field hints retain qualification and readback",
          arguments: ["Tempo", "BPM", "템포", "Position", "재생헤드 위치"])
    func legacyFieldAuthoritiesStillQualify(description: String) throws {
        let b = FakeAXRuntimeBuilder()
        let container = transportish(b, 904820, labels: ["Play"])
        let field = b.element(904821)
        b.setAttribute(field, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setAttribute(field, kAXDescriptionAttribute as String, description)
        let isPosition = description == "Position" || description == "재생헤드 위치"
        b.setAttribute(field, kAXValueAttribute as String, isPosition ? "37.3" : "128.5 BPM")
        b.setChildren(container, [b.element(9048201), field])
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [container], runtime: b.makeLogicRuntime())
        #expect(candidates.count == 1)
        #expect(CFEqual(try #require(candidates.first), container))
        let state = AXValueExtractors.extractTransportState(from: container, runtime: b.makeAXRuntime())
        if isPosition {
            #expect(state.position == "37.3")
            #expect(state.positionReadback?.observedComponents == [.bar, .beat])
        } else {
            #expect(state.tempo == 128.5)
        }
    }

    @Test("the container's existing numeric value fallbacks remain available",
          arguments: ["128 BPM", "00:01:02", "6.2.3"])
    func existingTextValueFallbacksStillQualify(value: String) throws {
        let b = FakeAXRuntimeBuilder()
        let container = transportish(b, 904830, labels: ["Play"]), field = b.element(904831)
        b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
        b.setAttribute(field, kAXValueAttribute as String, value)
        b.setChildren(container, [b.element(9048301), field])
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [container], runtime: b.makeLogicRuntime())
        #expect(candidates.count == 1)
        #expect(CFEqual(try #require(candidates.first), container))
    }

    @Test("field hints do not remove control, role, owner or diacritic boundaries",
          arguments: ["no_control", "wrong_role", "outside_owner", "accented", "unlabelled_prefix"])
    func textFieldQualificationBoundariesRemain(fault: String) {
        let b = FakeAXRuntimeBuilder()
        let container = transportish(b, 904840, labels: ["Play"]), field = b.element(904841)
        b.setAttribute(field, kAXRoleAttribute as String,
                       fault == "wrong_role" ? kAXImageRole as String : kAXStaticTextRole as String)
        b.setAttribute(field, kAXDescriptionAttribute as String,
                       fault == "accented" ? "Témpo" : fault == "unlabelled_prefix" ? "" : "템포")
        b.setAttribute(field, kAXValueAttribute as String, fault == "unlabelled_prefix" ? "37.3" : "128")
        if fault == "no_control" {
            b.setChildren(container, [field])
        } else if fault == "outside_owner" {
            b.setChildren(container, [b.element(9048401)])
        } else {
            b.setChildren(container, [b.element(9048401), field])
        }
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [container], runtime: b.makeLogicRuntime())
        #expect(candidates.isEmpty)
        if fault == "unlabelled_prefix" {
            let state = AXValueExtractors.extractTransportState(from: container, runtime: b.makeAXRuntime())
            #expect(state.positionReadback == nil)
            #expect(state.position == "1.1.1.1")
        }
    }

    @Test("text field traversal retains its four-level boundary", arguments: [4, 5])
    func textFieldDepthBoundaryRemains(depth: Int) throws {
        let b = FakeAXRuntimeBuilder()
        let container = transportish(b, 904850, labels: ["Play"]), field = b.element(904851)
        b.setAttribute(field, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setAttribute(field, kAXDescriptionAttribute as String, "テンポ")
        b.setAttribute(field, kAXValueAttribute as String, "128")
        var child = field
        for index in 1..<depth {
            let wrapper = b.element(904860 + index)
            b.setAttribute(wrapper, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setChildren(wrapper, [child])
            child = wrapper
        }
        b.setChildren(container, [b.element(9048501), child])
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [container], runtime: b.makeLogicRuntime())
        if depth == 4 {
            #expect(candidates.count == 1)
            #expect(CFEqual(try #require(candidates.first), container))
        } else {
            #expect(candidates.isEmpty)
        }
    }

    @Test("a field mentioning both authorities still uses tempo-first extraction")
    func tempoPrecedenceRemains() {
        let b = FakeAXRuntimeBuilder()
        let container = transportish(b, 904880, labels: ["Play"]), field = b.element(904881)
        b.setAttribute(field, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setAttribute(field, kAXDescriptionAttribute as String, "Tempo Position")
        b.setAttribute(field, kAXValueAttribute as String, "128.5")
        b.setChildren(container, [b.element(9048801), field])
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [container], runtime: b.makeLogicRuntime())
        #expect(candidates.count == 1)
        let state = AXValueExtractors.extractTransportState(from: container, runtime: b.makeAXRuntime())
        #expect(state.tempo == 128.5)
        #expect(state.positionReadback == nil)
    }

    /// Two containers that both satisfy the predicate by the control-keyword path: each holds a
    /// `record` and a `play` control, which is the two-hit rule the live tree also trips.
    private func transportish(_ b: FakeAXRuntimeBuilder, _ id: Int, labels: [String]) -> AXUIElement {
        let group = b.element(id)
        b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        var kids: [AXUIElement] = []
        for (i, label) in labels.enumerated() {
            let control = b.element(id * 10 + i + 1)
            b.setAttribute(control, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(control, kAXDescriptionAttribute as String, label)
            kids.append(control)
        }
        b.setChildren(group, kids)
        return group
    }

    @Test("two containers that both satisfy the predicate are both candidates")
    func twoSurvivorsAreBothListed() throws {
        let b = FakeAXRuntimeBuilder()
        let first = transportish(b, 6281, labels: ["Play", "Record"])
        let second = transportish(b, 6282, labels: ["Play", "Record"])
        let runtime = b.makeLogicRuntime()

        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [first, second], runtime: runtime)
        #expect(candidates.count == 2)

        // The chosen element is the first survivor — unchanged from `groups.first(where:)`.
        let chosen = try #require(candidates.first)
        #expect(CFEqual(chosen, first))
    }

    /// The count is what distinguishes a forced choice from a free one. A single survivor and four
    /// survivors both return something; only the count says which happened, and that is the whole
    /// sentence of this issue.
    @Test("one survivor and several survivors are told apart by the count, not by the result")
    func theCountIsWhatDistinguishes() throws {
        let b = FakeAXRuntimeBuilder()
        let transport = transportish(b, 6283, labels: ["Play", "Record"])
        let unrelated = b.element(6284)
        b.setAttribute(unrelated, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(unrelated, [])
        let runtime = b.makeLogicRuntime()

        let one = AXLogicProElements.transportContainerCandidates(
            among: [transport, unrelated], runtime: runtime)
        #expect(one.count == 1)

        let several = AXLogicProElements.transportContainerCandidates(
            among: [transport, transportish(b, 6285, labels: ["Play", "Record"])], runtime: runtime)
        #expect(several.count == 2)

        // Both return a non-nil first element. Without the count they are indistinguishable, which
        // is exactly the state this site was in.
        #expect(one.first != nil)
        #expect(several.first != nil)
    }

    /// The measured cause of 37 -> 4. Two labels that carry a transport keyword without being
    /// transport controls gave the ARRANGE AREA the two distinct keywords the rule requires:
    ///
    ///     "play" ⊂ "Catch Playhead"        "loop" ⊂ "Show/Hide Live Loops Grid"
    ///
    /// Measured live after the guard: survivors 4 -> 2, and both remaining are real control bars.
    @Test("a container whose only transport words are false friends is not a transport container")
    func falseFriendsDoNotQualify() throws {
        let b = FakeAXRuntimeBuilder()
        let arrangeish = transportish(b, 6340, labels: ["Catch Playhead", "Show/Hide Live Loops Grid"])
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [arrangeish], runtime: b.makeLogicRuntime())
        #expect(candidates.isEmpty)
    }

    /// The Korean forms are not translations of the English ones, and two of them keep English
    /// words inside a Korean UI — `Live Loop 그리드 보기/가리기` and `Session Player`. A guard
    /// written in one language would miss the other; both halves were read off a live window.
    @Test("the Korean forms of those labels are rejected too")
    func koreanFalseFriendsDoNotQualify() throws {
        let b = FakeAXRuntimeBuilder()
        let arrangeish = transportish(b, 6350, labels: ["재생헤드 캐치", "Live Loop 그리드 보기/가리기"])
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [arrangeish], runtime: b.makeLogicRuntime())
        #expect(candidates.isEmpty)
    }

    /// The guard must not swallow the real thing. A container holding genuine transport controls
    /// still qualifies, including one whose OTHER labels are false friends.
    @Test("a real transport container still qualifies alongside false friends")
    func realControlsStillQualify() throws {
        let b = FakeAXRuntimeBuilder()
        let realBar = transportish(b, 6360, labels: ["Play", "Record", "Catch Playhead"])
        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [realBar], runtime: b.makeLogicRuntime())
        #expect(candidates.count == 1)
    }

    @Test("no survivor is an empty list, not a nil element hiding a count of zero")
    func noSurvivor() throws {
        let b = FakeAXRuntimeBuilder()
        let empty = b.element(6286)
        b.setAttribute(empty, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(empty, [])

        let candidates = AXLogicProElements.transportContainerCandidates(
            among: [empty], runtime: b.makeLogicRuntime())
        #expect(candidates.isEmpty)
        #expect(candidates.first == nil)
    }

    /// **This replaces a tautological case.** The old test compared
    /// `transportContainerCandidates(among:).first` against
    /// `groups.first(where: looksLikeTransportContainer)` — the same predicate on both sides, so it
    /// could not fail, and reverting the production change would have left it green. A reviewer
    /// pointed that out; it was proving that `filter().first == first(where:)` in Swift.
    ///
    /// What actually needs pinning is the COMPOSITION: `getTransportBar` consults `getControlBar`
    /// first, and `getControlBar` has a branch that returns a lone labelled group holding no
    /// checkbox at all. Composing that unconditionally lets a labelled shell shadow a container
    /// that works — `findTransportButton` would search only the shell and return nil.
    @Test("a labelled Control Bar holding no transport control does not shadow one that works")
    func labelledShellDoesNotShadowAWorkingContainer() throws {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(6390)
        let window = b.element(6391)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)

        // Described "Control Bar" — so `getControlBar` finds it — but holding nothing.
        let shell = b.element(6392)
        b.setAttribute(shell, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(shell, kAXDescriptionAttribute as String, "Control Bar")
        b.setChildren(shell, [])

        // ORDER MATTERS, and getting it wrong made this test assert the wrong thing once. With the
        // shell FIRST, the bare scan returns it too — `looksLikeTransportContainer` matches on
        // metadata, so "Control Bar" qualifies with nothing inside, and that is pre-existing
        // behaviour this branch does not change. The regression the composition introduces is only
        // visible when the WORKING container comes first: the scan would have taken it, and
        // consulting `getControlBar` first takes the shell instead.
        let working = transportish(b, 6393, labels: ["Play", "Record"])
        b.setChildren(window, [working, shell])
        let runtime = b.makeLogicRuntime(appElement: app)

        let found = try #require(AXLogicProElements.getTransportBar(runtime: runtime))
        #expect(CFEqual(found, working))
        #expect(!CFEqual(found, shell))
    }

    /// The other half: when the labelled bar DOES hold transport controls it is still preferred,
    /// so the validation above did not simply disable the discriminated accessor.
    @Test("a labelled Control Bar that holds transport controls is still preferred")
    func labelledBarWithControlsIsPreferred() throws {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(6395)
        let window = b.element(6396)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)

        let realBar = transportish(b, 6397, labels: ["Play", "Record"])
        b.setAttribute(realBar, kAXDescriptionAttribute as String, "Control Bar")
        // A second qualifying container EARLIER in tree order, which the bare scan would take.
        let other = transportish(b, 6398, labels: ["Play", "Record"])
        b.setChildren(window, [other, realBar])
        let runtime = b.makeLogicRuntime(appElement: app)

        let found = try #require(AXLogicProElements.getTransportBar(runtime: runtime))
        #expect(CFEqual(found, realBar))
    }
}
