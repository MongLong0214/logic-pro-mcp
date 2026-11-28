@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Models what was measured on Logic Pro 13.0 (7801), ko-KR: the track-header rail's
/// AXSelectedChildren setter returns success and the selection does not move; writing the main
/// Mixer's AXSelectedChildren with a strip selects that strip's track and makes the strip the
/// Mixer's selected child. A strip that belongs to no track (an output) becomes the selected child
/// and leaves the track selection where it was. Header names, strip descriptions and strip order
/// are set independently, because on Logic they are independent: a strip is described by its
/// channel name, which a track rename leaves stale. Its name field reads its track's name. The
/// Mixer sits beside its own toolbar under one owner, as on Logic 13.0: a mode radio group
/// (Single, Tracks, All) and eight type-filter checkboxes.
private final class Logic13SelectFixture: @unchecked Sendable {
    struct Strip {
        let description: String
        /// The header row this strip selects, or nil for a strip that belongs to no track.
        let owner: Int?
        init(_ description: String, _ owner: Int?) { self.description = description; self.owner = owner }
    }

    static let modeTitles = ["Single", "Tracks", "All"]

    let b = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let rail: AXUIElement
    let mixer: AXUIElement?
    let editor: AXUIElement
    private(set) var rows: [AXUIElement] = []
    private(set) var strips: [AXUIElement] = []
    private let owners: [Int?]
    private var fields: [AXUIElement] = []
    private(set) var events: [String] = []
    private(set) var helpReads = 0
    private(set) var activations = 0
    private(set) var revoked = false
    /// Withdraw the caller's permission as soon as a Mixer strip's own attributes are read: the
    /// reads a fallback makes to decide which strip to write.
    var revokeOnStripRead = false
    /// Replace this row's header element with a new one when a write selects it.
    var recycleRowOnSelect: Int?
    /// Refuse every Mixer write after this many, without moving anything.
    var mixerWritesAccepted: Int?
    private var mixerWrites = 0

    init(headers: [String], strips stripSpecs: [Strip], selected: Int,
         withMixer: Bool = true, editorOpen: Bool = false, mode: Int = 1, filtersOff: Set<Int> = []) {
        owners = stripSpecs.map(\.owner)
        app = b.element(1_600_000)
        window = b.element(1_600_001)
        rail = b.element(1_600_002)
        mixer = withMixer ? b.element(1_600_003) : nil
        editor = b.element(1_600_004)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(window, kAXTitleAttribute as String, "Fix1600 - Tracks")
        b.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Fix1600.logicx")
        b.setAttribute(rail, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(rail, kAXDescriptionAttribute as String, "Track Headers")
        b.setAttribute(editor, kAXRoleAttribute as String, kAXTextFieldRole as String)
        for (i, name) in headers.enumerated() {
            let row = b.element(1_600_100 + i)
            let field = b.element(1_600_200 + i)
            b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, name)
            b.setChildren(field, [])
            b.setChildren(row, [field])
            rows.append(row)
            fields.append(field)
        }
        b.setChildren(rail, rows)
        var windowChildren: [AXUIElement] = [rail]
        if let mixer {
            b.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
            for (i, spec) in stripSpecs.enumerated() {
                let strip = b.element(1_600_300 + i)
                let name = b.element(1_600_400 + i)
                b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
                b.setAttribute(strip, kAXDescriptionAttribute as String, spec.description)
                b.setAttribute(strip, kAXParentAttribute as String, mixer)
                b.setAttribute(name, kAXRoleAttribute as String, kAXTextFieldRole as String)
                b.setAttribute(name, kAXValueAttribute as String, spec.owner.map { headers[$0] } ?? spec.description)
                b.setChildren(name, [])
                b.setChildren(strip, [name])
                strips.append(strip)
            }
            b.setChildren(mixer, strips)
            b.setAttributeSettable(mixer, kAXSelectedChildrenAttribute as String, true)
            let owner = b.element(1_600_005)
            let toolbar = b.element(1_600_006)
            let modeGroup = b.element(1_600_007)
            let filterGroup = b.element(1_600_008)
            for element in [owner, toolbar, filterGroup] {
                b.setAttribute(element, kAXRoleAttribute as String, kAXGroupRole as String)
            }
            b.setAttribute(modeGroup, kAXRoleAttribute as String, kAXRadioGroupRole as String)
            let radios = Self.modeTitles.enumerated().map { i, title -> AXUIElement in
                let radio = b.element(1_600_010 + i)
                b.setAttribute(radio, kAXRoleAttribute as String, kAXRadioButtonRole as String)
                b.setAttribute(radio, kAXDescriptionAttribute as String, title)
                b.setAttribute(radio, kAXValueAttribute as String, NSNumber(value: i == mode ? 1 : 0))
                b.setChildren(radio, [])
                return radio
            }
            let checkboxes = (0..<8).map { i -> AXUIElement in
                let box = b.element(1_600_020 + i)
                b.setAttribute(box, kAXRoleAttribute as String, kAXCheckBoxRole as String)
                b.setAttribute(box, kAXValueAttribute as String, NSNumber(value: filtersOff.contains(i) ? 0 : 1))
                b.setChildren(box, [])
                return box
            }
            b.setChildren(modeGroup, radios)
            b.setChildren(filterGroup, checkboxes)
            b.setChildren(toolbar, [modeGroup, filterGroup])
            b.setChildren(owner, [toolbar, mixer])
            b.setAttribute(mixer, kAXParentAttribute as String, owner)
            windowChildren.append(owner)
        }
        b.setChildren(window, windowChildren)
        b.setChildren(app, [window])
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(app, kAXFocusedUIElementAttribute as String, editorOpen ? editor : rail)
        selectRow(selected)
    }

    /// Select one row exclusively, as Logic does, and give the Mixer that row's strip as its
    /// selected child.
    private func selectRow(_ target: Int) {
        if recycleRowOnSelect == target {
            let replacement = b.element(1_600_150 + target)
            b.setAttribute(replacement, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setChildren(replacement, [fields[target]])
            rows[target] = replacement
            b.setChildren(rail, rows)
        }
        for (i, row) in rows.enumerated() {
            b.setAttribute(row, kAXSelectedAttribute as String, NSNumber(value: i == target ? 1 : 0))
        }
        b.setAttribute(rail, kAXSelectedChildrenAttribute as String, [rows[target]])
        if let mixer, let strip = owners.firstIndex(where: { $0 == target }) {
            b.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [strips[strip]])
        }
    }

    /// Add a second selected row without changing the Mixer.
    func alsoSelect(_ row: Int) {
        b.setAttribute(rows[row], kAXSelectedAttribute as String, NSNumber(value: 1))
    }

    var mixerSelectedStrip: Int? {
        guard let mixer, let selected = b.attributeValue(mixer, kAXSelectedChildrenAttribute as String) as? [AXUIElement],
              selected.count == 1 else { return nil }
        return strips.firstIndex { CFEqual($0, selected[0]) }
    }

    var runtime: AXLogicProElements.Runtime {
        b.makeLogicRuntime(
            pid: 1_600_900, appElement: app,
            attributeValueHandler: { [self] element, attribute in
                if attribute == kAXHelpAttribute as String { helpReads += 1 }
                if revokeOnStripRead, strips.contains(where: { CFEqual($0, element) }),
                   ![kAXRoleAttribute as String, kAXIdentifierAttribute as String,
                     kAXChildrenAttribute as String].contains(attribute) {
                    revoked = true
                }
                return nil
            },
            setAttributeHandler: { [self] element, attribute, value in
                if CFEqual(element, rail), attribute == kAXSelectedChildrenAttribute as String {
                    events.append("rail_write")
                    return true // acknowledged, selection does not move
                }
                if let mixer, CFEqual(element, mixer), attribute == kAXSelectedChildrenAttribute as String,
                   let strip = (value as? [AXUIElement])?.first,
                   let i = strips.firstIndex(where: { CFEqual($0, strip) }) {
                    events.append("mixer_write:\(i)")
                    mixerWrites += 1
                    if let accepted = mixerWritesAccepted, mixerWrites > accepted { return false }
                    if let owner = owners[i] {
                        selectRow(owner)
                    }
                    b.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [strips[i]])
                    return true
                }
                events.append("other_write:\(attribute)")
                return false
            },
            performActionHandler: { [self] _, action in
                events.append("action:\(action)")
                return false
            }
        )
    }

    var processRuntime: ProcessUtils.Runtime {
        ProcessUtils.Runtime(
            logicProPID: { 1_600_900 }, fallbackLogicProPID: { 1_600_900 }, logicProRunning: { true },
            activateLogicPro: { [self] in activations += 1; return true },
            logicIsFrontmost: { true }, logicProBundleURL: { nil }
        )
    }

    func select(_ index: Int) -> Bool {
        AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime)
    }

    func outcome(_ index: Int) -> AXLogicProElements.TrackSelectionOutcome {
        AXLogicProElements.selectTrackOutcome(at: index, runtime: runtime)
    }

    func publicSelect(_ index: Int) async -> ChannelResult {
        await AccessibilityChannel.defaultSelectTrack(
            params: ["index": "\(index)"], runtime: runtime, processRuntime: processRuntime)
    }

    func verify(_ index: Int) async -> AccessibilityChannel.TrackSelectionVerification {
        await AccessibilityChannel.verifyTrackSelection(index: index, runtime: runtime)
    }
}

private func inOrder(_ names: [String]) -> [Logic13SelectFixture.Strip] {
    names.enumerated().map { .init($1, $0) }
}

@Suite("Issue 1600: tracks.select on Logic 13")
struct Issue1600TrackSelectLogic13Tests {
    private let names = ["Audio 1", "Audio 2", "Deluxe Classic", "Studio Grand"]

    @Test func selectMovesSelectionThroughTheMixerRelationshipWhenRailWriteIsAckedWithoutEffect() async {
        let f = Logic13SelectFixture(headers: names, strips: inOrder(names) + [.init("Stereo Out", nil)], selected: 2)
        #expect(f.select(0))
        #expect(f.events == ["rail_write", "mixer_write:0"])
        #expect(await f.verify(0) == .verified)
        #expect(f.mixerSelectedStrip == 0)
    }

    /// TRACK-1600-TEST-ACTIVATION: activation is injected, so this never reaches a real Logic.
    @Test func defaultSelectTrackReportsStateAWithInjectedActivation() async {
        let f = Logic13SelectFixture(headers: names, strips: inOrder(names), selected: 2)
        let result = await AccessibilityChannel.defaultSelectTrack(
            params: ["index": "3"], runtime: f.runtime, processRuntime: f.processRuntime)
        guard case .success(let text) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(text.contains("\"state\":\"A\"") || text.contains("\"state\" : \"A\""))
        #expect(f.events == ["rail_write", "mixer_write:3"])
        #expect(f.activations == 1)
    }

    /// TRACK-1600-IDENTITY: headers A, B, C over strips described "Old A", "A", "C". The strip
    /// that carries the name "A" is B's; the request for A must write A's own strip, and its
    /// neighbour B must get B's.
    @Test func anIndependentlyRenamedChannelDoesNotSendTheWriteToTheStripCarryingTheName() async {
        let f = Logic13SelectFixture(headers: ["A", "B", "C"],
                                     strips: [.init("Old A", 0), .init("A", 1), .init("C", 2)], selected: 2)
        #expect(f.select(0))
        #expect(f.events == ["rail_write", "mixer_write:0"])
        #expect(await f.verify(0) == .verified)
        #expect(f.select(1))
        #expect(f.events == ["rail_write", "mixer_write:0", "rail_write", "mixer_write:1"])
        #expect(await f.verify(1) == .verified)
    }

    /// A name carried twice on one side only is not an identity question any more: the strip is
    /// bound through the Mixer's relationship, not through a name.
    @Test func aNameCarriedTwiceOnOneSideDoesNotBlockOrMisdirectTheWrite() async {
        let headerSide = Logic13SelectFixture(headers: ["Audio", "Audio", "Keys"],
                                              strips: [.init("Audio", 0), .init("Bass", 1), .init("Keys", 2)], selected: 2)
        #expect(headerSide.select(1))
        #expect(headerSide.events == ["rail_write", "mixer_write:1"])
        #expect(await headerSide.verify(1) == .verified)

        let stripSide = Logic13SelectFixture(headers: ["Audio 1", "Audio 2", "Keys"],
                                             strips: [.init("Audio", 0), .init("Audio", 1), .init("Keys", 2)], selected: 2)
        #expect(stripSide.select(0))
        #expect(stripSide.events == ["rail_write", "mixer_write:0"])
        #expect(await stripSide.verify(0) == .verified)
    }

    /// A Mixer whose order differs from the headers', seen at the one strip whose header is known
    /// (the selected C's strip is first, C is third): nothing binds the requested header, so no
    /// strip is written and the selection stays.
    @Test func aReorderedMixerRefusesBeforeWritingAndKeepsTheSelection() async {
        let f = Logic13SelectFixture(headers: ["A", "B", "C"],
                                     strips: [.init("C", 2), .init("A", 0), .init("B", 1)], selected: 2)
        #expect(f.select(0))
        #expect(f.events == ["rail_write"])
        #expect(await f.verify(0) == .mismatch(selectedIndex: 2))
        #expect(f.mixerSelectedStrip == 0)
    }

    /// TRACK-1600-IDENTITY: a reordered Mixer that lines up at the selected row (strips B, A, C under
    /// headers A, B, C with C selected). One aligned row is not a mapping for the whole Mixer, so the
    /// request for A is refused before any Mixer write: B is never selected, C stays.
    @Test func aReorderedMixerThatLinesUpAtTheSelectedRowRefusesBeforeAnyMixerWrite() async {
        let f = Logic13SelectFixture(headers: ["A", "B", "C"],
                                     strips: [.init("B", 1), .init("A", 0), .init("C", 2)], selected: 2)
        #expect(f.outcome(0) == .mixerRefused("mixer_strips_differ_from_track_headers"))
        #expect(f.events == ["rail_write"])
        #expect(await f.verify(2) == .verified)
        #expect(f.mixerSelectedStrip == 2)
    }

    /// Different populations: an output strip among the tracks' strips. Refused before writing.
    @Test func aStripThatBelongsToNoTrackAmongTheTracksRefusesBeforeWriting() async {
        let f = Logic13SelectFixture(headers: ["A", "B", "C"],
                                     strips: [.init("A", 0), .init("Stereo Out", nil), .init("B", 1), .init("C", 2)],
                                     selected: 0)
        #expect(f.outcome(1) == .mixerRefused("mixer_strips_differ_from_track_headers"))
        #expect(f.events == ["rail_write"])
        #expect(await f.verify(0) == .verified)
    }

    /// Measured on Logic 13.0, standard fixture: in All view Logic put Preview between the audio and
    /// instrument strips. Even where the strips happen to line up, All view is refused.
    @Test func theMixerInAllViewRefusesBeforeAnyMixerWrite() async {
        let f = Logic13SelectFixture(headers: names, strips: inOrder(names), selected: 2, mode: 2)
        let result = await f.publicSelect(0)
        #expect(f.events == ["rail_write"])
        #expect(await f.verify(2) == .verified)
        guard case .success(let text) = result else { Issue.record("expected State B, got \(result)"); return }
        #expect(text.contains("mixer_not_in_tracks_view"))
        #expect(!channelResultIsVerified(result))
    }

    /// Measured on Logic 13.0: with the Audio type filter off in Tracks view the audio strips left the
    /// Mixer and every later strip moved up. A filter that is off refuses.
    @Test func aTypeFilterThatIsOffRefusesBeforeAnyMixerWrite() async {
        let f = Logic13SelectFixture(headers: names, strips: inOrder(names), selected: 2, filtersOff: [0])
        #expect(f.outcome(0) == .mixerRefused("mixer_type_filter_off"))
        #expect(f.events == ["rail_write"])
        #expect(await f.verify(2) == .verified)
    }

    /// After the write, only the SAME retained header counts: a new element in its row does not.
    /// The original strip is written back, and the attempt is still a failure.
    @Test func aRecycledTargetRowIsNotTakenForTheRetainedHeader() async {
        let f = Logic13SelectFixture(headers: ["A", "B", "C"], strips: inOrder(["A", "B", "C"]), selected: 2)
        f.recycleRowOnSelect = 0
        #expect(f.outcome(0) == .mixerUnsettled)
        #expect(f.events == ["rail_write", "mixer_write:0", "mixer_write:2"])
        #expect(await f.verify(2) == .verified)
    }

    /// TRACK-1600-OUTCOME: the write selects a replacement header at the requested row and the
    /// restore is refused, so the replacement stays the only selected row. The ordinal read-back
    /// would call that State A; the failure must reach the caller instead, and delete and duplicate,
    /// which act on the selection, must not be sent.
    @Test func aRecycledRowWithARefusedRestoreIsNotStateAAndStopsDeleteAndDuplicate() async throws {
        let f = Logic13SelectFixture(headers: ["A", "B", "C"], strips: inOrder(["A", "B", "C"]), selected: 2)
        f.recycleRowOnSelect = 0
        f.mixerWritesAccepted = 1
        let result = await f.publicSelect(0)
        #expect(f.events == ["rail_write", "mixer_write:0", "mixer_write:2"])
        #expect(await f.verify(0) == .verified)
        guard case .error(let text) = result else { Issue.record("expected State C, got \(result)"); return }
        #expect(text.contains("mixer_write_unsettled"))
        #expect(!channelResultIsVerified(result))

        let select = FixedSelectChannel(result: result)
        let keyCmd = MockChannel(id: .midiKeyCommands)
        let router = ChannelRouter()
        await router.register(select)
        await router.register(keyCmd)
        for command in ["delete", "duplicate"] {
            let answer = await TrackDispatcher.handle(
                command: command, params: ["index": .int(0), "expected_name": .string("A")],
                router: router, cache: StateCache(), liveTrackNames: sharedLiveTrackNames([0: "A"]))
            let refused = try #require(answer.isError)
            #expect(refused)
        }
        #expect(await select.selects == 2)
        #expect(await keyCmd.executedOps.isEmpty)
    }

    /// Two rows selected: there is no single header whose strip the Mixer names, so nothing binds.
    @Test func anUnreadRelationshipRefusesBeforeWriting() async {
        let f = Logic13SelectFixture(headers: names, strips: inOrder(names), selected: 2)
        f.alsoSelect(1)
        #expect(f.outcome(0) == .mixerRefused("selection_not_exclusive"))
        #expect(f.events == ["rail_write"])
    }

    /// TRACK-1600-CUSTODY: the caller's permission is withdrawn while the fallback reads the strips
    /// it decides by. The check must come after those reads, at the setter: no Mixer write.
    @Test func permissionWithdrawnDuringTheFinalStripReadsStopsTheMixerWrite() async {
        let f = Logic13SelectFixture(headers: names, strips: inOrder(names), selected: 2)
        f.revokeOnStripRead = true
        let selected = AXLogicProElements.selectTrackViaAX(at: 0, runtime: f.runtime,
                                                          permittingWrite: { !f.revoked }, willWrite: {})
        #expect(f.revoked)
        #expect(!f.events.contains { $0.hasPrefix("mixer_write") })
        #expect(!selected)
        #expect(await f.verify(0) == .mismatch(selectedIndex: 2))
    }

    /// TRACK-1600-EDITOR: the Mixer route reads no AXHelp, which ends an inline rename.
    @Test func theMixerRouteReadsNoHelp() {
        let f = Logic13SelectFixture(headers: ["A", "B", "C"],
                                     strips: [.init("Old A", 0), .init("A", 1), .init("C", 2)], selected: 2)
        _ = f.select(0)
        #expect(f.events.contains("mixer_write:0"))
        #expect(f.helpReads == 0)
    }

    /// TRACK-1600-EDITOR: with a text editor focused, track.select refuses before activating,
    /// reading the headers or writing anything, as mute, solo and arm do.
    @Test func anOpenTextEditorRefusesSelectBeforeActivationOrAnyWrite() async {
        let f = Logic13SelectFixture(headers: names, strips: inOrder(names), selected: 2, editorOpen: true)
        let result = await AccessibilityChannel.defaultSelectTrack(
            params: ["index": "0"], runtime: f.runtime, processRuntime: f.processRuntime)
        guard case .error(let text) = result else { Issue.record("expected a refusal, got \(result)"); return }
        #expect(text.contains("unsafe_focus_for_synthetic_key"))
        #expect(text.contains("track selection"))
        #expect(f.events.isEmpty)
        #expect(f.activations == 0)
        #expect(f.helpReads == 0)
        #expect(await f.verify(2) == .verified)
    }

    @Test func withoutAMixerTheNoOpIsReportedAsMismatchNotSelected() async {
        let f = Logic13SelectFixture(headers: names, strips: [], selected: 2, withMixer: false)
        #expect(f.select(1))
        #expect(f.events == ["rail_write"])
        #expect(await f.verify(1) == .mismatch(selectedIndex: 2))
    }
}

/// Answers `track.select` with a result the real Accessibility path produced, and counts the calls.
private actor FixedSelectChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    let result: ChannelResult
    private(set) var selects = 0
    init(result: ChannelResult) { self.result = result }
    func start() async throws {}
    func stop() async {}
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        if operation == "track.select" { selects += 1; return result }
        return .error("unexpected \(operation)")
    }
    func healthCheck() async -> ChannelHealth { .healthy(detail: "fixed select") }
}
