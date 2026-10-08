@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// #291 R2 — `logic_mixer set_output_verified`. The fixture is the output popup as measured on
// Logic 12.3 in ko and de on 2026-09-28: pressing a strip's output slot parents one AXMenu to the
// Mixer's AXLayoutArea; its root holds a checked echo of the CURRENT output, `No Output`, an Output
// submenu that holds `Stereo Output` and `Output 3-4`, and a Bus submenu whose first entry reads
// `Bus 1 → Aux 1` because an aux already takes Bus 1. Pressing an entry closes the menu and
// REPLACES the strip: the held strip and its slots answer -25202 from then on, and a new strip at
// the same ordinal carries the new output (measured ko: invalid from about 0.6 s after the press).
// A bus nothing receives makes Logic add an aux strip, which the fixture models too.

private let r2PID: pid_t = 4291
private let r2InvalidElement = AXHelpers.AXStatusError(raw: -25202)
private let r2CannotComplete = AXHelpers.AXStatusError(raw: -25204)
private let r2NoValue = AXHelpers.AXStatusError(raw: -25212)
private let r2AttributeUnsupported = AXHelpers.AXStatusError(raw: -25205)

/// The labels one Logic language draws in the output popup and on the slot.
struct R2PopupLanguage: Sendable, CustomStringConvertible {
    let name: String
    let stereoOutput: String
    let noOutput: String
    let outputSubmenu: String
    let pair34: String
    let monoSubmenu: String
    let monoEntries: [String]
    let surround: String
    let busSubmenu: String
    let busWord: String
    let pan: String
    var description: String { name }

    func bus(_ number: Int) -> String { "\(busWord) \(number)" }

    static let en = R2PopupLanguage(
        name: "en", stereoOutput: "Stereo Output", noOutput: "No Output", outputSubmenu: "Output",
        pair34: "Output 3-4", monoSubmenu: "Mono", monoEntries: ["Output 1", "Output 2"],
        surround: "Surround", busSubmenu: "Bus", busWord: "Bus", pan: "Pan"
    )
    /// Measured: the ko popup keeps `Stereo Output` in English and draws the rest in Korean.
    static let ko = R2PopupLanguage(
        name: "ko", stereoOutput: "Stereo Output", noOutput: "출력 없음", outputSubmenu: "출력",
        pair34: "출력 3-4", monoSubmenu: "모노", monoEntries: ["출력 1", "출력 2"],
        surround: "서라운드", busSubmenu: "버스", busWord: "버스", pan: "패닝"
    )
    /// Measured: German draws the Output submenu AND its pairs with `Ausgang`, not `Output`.
    static let de = R2PopupLanguage(
        name: "de", stereoOutput: "Stereo-Ausgabe", noOutput: "Kein Ausgang", outputSubmenu: "Ausgang",
        pair34: "Ausgang 3-4", monoSubmenu: "Mono", monoEntries: ["Ausgang 1", "Ausgang 2"],
        surround: "Surround", busSubmenu: "Bus", busWord: "Bus", pan: "Pan"
    )
}

private enum R2SourcePopupDrift: String, CaseIterable, Sendable {
    case reordered, replaced
}

private final class R2Fixture: @unchecked Sendable {
    enum CurrentOutput { case stereo, bus(Int), label(String), blank }
    enum AfterPress { case applies, doesNothing, slotGoesBlank }
    enum AuxSend { case none, empty, occupied }
    /// A read that fails with -25204, which is not an answer.
    enum FailingRead { case sourceInputRole, thirdStripChildren, secondBusOneTitle, nestedBusItemChildren }
    /// A read of the second `Bus 1` entry that ANSWERS with an AX status (#1062 review R2-03):
    /// -25212 or -25205, injected explicitly, because the builder reads an unset attribute as
    /// success-and-nil and that would not exercise the status path.
    enum AnsweringRead { case secondBusOneTitle(AXHelpers.AXStatusError), secondBusOneRole(AXHelpers.AXStatusError) }
    /// The root's first entry as measured on Logic 12.3 ko: a menu item whose title answers -25212
    /// and whose single child is an AXTextField holding one AXButton (the popup's search field).
    /// `withSubmenu` adds an AXMenu child beside the text field, which makes it not a search field.
    enum UntitledRootItem { case searchField, withSubmenu }

    struct Options {
        var language = R2PopupLanguage.en
        var current = CurrentOutput.stereo
        /// Strip 0's input. A bus here is what lets an output assignment close a loop.
        var sourceInput = "Input 1"
        var auxInput: String?
        var auxOutput: String?
        var auxSend = AuxSend.none
        var failingRead: FailingRead?
        var afterPress = AfterPress.applies
        /// Logic adds an aux for a bus no strip receives; `always` makes any press add one.
        var alwaysCreatesStrip = false
        var play: Bool? = false
        var record: Bool? = false
        var duplicateSubmenuStereoOutput = false
        var duplicateBusOne = false
        var answeringRead: AnsweringRead?
        var untitledRootItem: UntitledRootItem?
        /// The source strip's input-slot help; nil keeps the measured "Input slot." wording. A help
        /// that names no known slot is an input slot this project's LabelSet does not recognise.
        var sourceInputHelp: String?
        /// False: the press puts a popup-level window up, but no AXMenu appears under the Mixer.
        var menuAppearsUnderMixer = true
        /// Aux 1's input becomes this when the output popup opens, as a user reassigning it would.
        var auxInputWhilePopupOpen: String?
        /// How that change reaches AX: the input slot relabelled, or the strip's elements replaced.
        var auxChange = R2ReceiverChange.inPlace
        /// A strip is added to the Mixer when the output popup opens.
        var stripAddedWhilePopupOpen = false
        /// Synthetic source drift during the opener, before any terminal entry is selected.
        var sourceDriftWhilePopupOpen: R2SourcePopupDrift?
    }

    let options: Options
    let b = FakeAXRuntimeBuilder()
    private let lock = NSLock()
    private var nextID = 291_20_000
    private var menuOpen = false
    private var pressLog: [Int] = []
    private var escapes = 0
    private var resultLabel: [Int: String] = [:]
    private var stripChildren: [Int: [AXUIElement]] = [:]
    private var invalidated: Set<Int> = []
    private var failingAttribute: [Int: String] = [:]
    private var answeringAttribute: [Int: (String, AXHelpers.AXStatusError)] = [:]
    private var failingChildren: Set<Int> = []
    private var replacedStrips = 0
    private var sourceOpenerDrifts = 0
    private var sourceOpenerStripSnapshot: [AXUIElement]?
    private var auxInputNow = ""

    private(set) var app: AXUIElement!
    private(set) var mixer: AXUIElement!
    private(set) var strips: [AXUIElement] = []
    private(set) var outputButton: AXUIElement!
    private(set) var root: AXUIElement!
    private(set) var rootEcho: AXUIElement!
    private(set) var submenuStereoOutput: AXUIElement!
    private(set) var busOne: AXUIElement!
    private(set) var secondBusOne: AXUIElement?
    private(set) var untitledRootEntry: AXUIElement?
    private(set) var pair34: AXUIElement!

    init(_ options: Options = Options()) {
        self.options = options
        let language = options.language
        auxInputNow = options.auxInput ?? language.bus(1)
        app = make()
        let window = make()
        b.setAttribute(app, kAXMainWindowAttribute as String, window)

        let controlBar = make(role: kAXGroupRole as String, description: "Control Bar")
        let play = make(role: kAXCheckBoxRole as String, description: "Play")
        let record = make(role: kAXCheckBoxRole as String, description: "Record")
        if let value = options.play { b.setAttribute(play, kAXValueAttribute as String, NSNumber(value: value ? 1 : 0)) }
        if let value = options.record { b.setAttribute(record, kAXValueAttribute as String, NSNumber(value: value ? 1 : 0)) }
        b.setChildren(controlBar, [play, record])

        mixer = make(role: "AXLayoutArea", description: "Mixer")
        let current: String
        switch options.current {
        case .stereo: current = language.stereoOutput
        case .bus(let number): current = language.bus(number)
        case .label(let label): current = label
        case .blank: current = ""
        }
        let (audio, audioOutput) = strip(output: current, input: options.sourceInput, inputHelp: options.sourceInputHelp)
        outputButton = audioOutput
        let (aux, _) = strip(output: options.auxOutput ?? language.stereoOutput,
                             input: options.auxInput ?? language.bus(1), send: options.auxSend)
        let (stereoOut, _) = strip(output: nil, input: nil)
        strips = [audio, aux, stereoOut]
        b.setChildren(mixer, strips)
        b.setChildren(window, [controlBar, mixer])
        buildPopup(current: current)
        switch options.failingRead {
        case .sourceInputRole: failingAttribute[id(stripChildren[id(audio)]![0])] = kAXRoleAttribute as String
        case .thirdStripChildren: failingChildren.insert(id(stereoOut))
        case .secondBusOneTitle, .nestedBusItemChildren, nil: break
        }
    }

    var runtime: AXLogicProElements.Runtime {
        let base = b.makeLogicRuntime(
            pid: r2PID,
            appElement: app,
            attributeValueHandler: { [self] element, _ -> AnyObject?? in isGone(element) ? .some(nil) : .none },
            attributeValueResultHandler: { [self] element, attribute in
                if isGone(element) { return .failure(r2InvalidElement) }
                if let (answered, status) = answeringAttribute[id(element)], answered == attribute {
                    return .failure(status)
                }
                return failingAttribute[id(element)] == attribute ? .failure(r2CannotComplete) : nil
            },
            childrenHandler: { [self] element in isGone(element) ? [] : nil },
            childrenResultHandler: { [self] element in
                if isGone(element) { return .failure(r2InvalidElement) }
                return failingChildren.contains(id(element)) ? .failure(r2CannotComplete) : nil
            },
            setAttributeHandler: nil,
            performActionHandler: { [self] element, action in press(element, action) }
        )
        return AXLogicProElements.Runtime(
            logicProPID: base.logicProPID,
            ax: base.ax,
            executeAppleScript: base.executeAppleScript,
            executeAppleScriptWithTimeout: base.executeAppleScriptWithTimeout,
            onScreenWindowList: { [self] in windows() },
            postPopupMenuEscape: { [self] in escape() }
        )
    }

    var presses: [Int] { lock.withLock { pressLog } }
    var escapeCount: Int { lock.withLock { escapes } }
    var stripsReplaced: Int { lock.withLock { replacedStrips } }
    var sourceOpenerDriftCount: Int { lock.withLock { sourceOpenerDrifts } }
    var stripsAtSourceOpenerDrift: [AXUIElement]? { lock.withLock { sourceOpenerStripSnapshot } }
    func id(_ element: AXUIElement) -> Int { b.elementID(element) }
    func isGone(_ element: AXUIElement) -> Bool { lock.withLock { invalidated.contains(id(element)) } }

    private func make(role: String? = nil, description: String? = nil) -> AXUIElement {
        nextID += 1
        let element = b.element(nextID)
        if let role { b.setAttribute(element, kAXRoleAttribute as String, role) }
        if let description { b.setAttribute(element, kAXDescriptionAttribute as String, description) }
        return element
    }

    private func strip(
        output: String?, input: String?, send: AuxSend = .none, inputHelp: String? = nil
    ) -> (AXUIElement, AXUIElement?) {
        let strip = make(role: kAXLayoutItemRole as String)
        var children: [AXUIElement] = []
        var outputSlot: AXUIElement?
        if let input {
            let slot = make(role: kAXButtonRole as String, description: input)
            b.setAttribute(slot, kAXHelpAttribute as String,
                           inputHelp ?? "Input slot. Click and hold to choose the channel strip input.")
            children.append(slot)
        }
        if send != .none {
            // Measured shape: an occupied send is a send-slot button followed by its level knob.
            let slot = make(role: kAXButtonRole as String, description: "send button")
            b.setAttribute(slot, kAXHelpAttribute as String, "Send slot. Click to choose a send destination.")
            children.append(slot)
            if send == .occupied {
                let knob = make(role: kAXSliderRole as String, description: "send level")
                b.setAttribute(knob, kAXHelpAttribute as String, "Send Level knob. Drag to set the send level.")
                children.append(knob)
            }
        }
        if let output {
            let slot = make(role: kAXButtonRole as String, description: output)
            b.setAttribute(slot, kAXHelpAttribute as String, "Output slot. Click and hold to choose the channel strip output.")
            children.append(slot)
            outputSlot = slot
        }
        b.setChildren(strip, children)
        stripChildren[id(strip)] = children
        return (strip, outputSlot)
    }

    /// Logic replaces the audio strip's elements when its output changes: the old strip and its
    /// slots answer -25202, and a new strip at the same ordinal carries the new output.
    private func replaceAudioStrip(output: String) {
        let old = strips[0]
        invalidated.insert(id(old))
        for child in stripChildren[id(old)] ?? [] { invalidated.insert(id(child)) }
        strips[0] = strip(output: output, input: options.sourceInput, inputHelp: options.sourceInputHelp).0
        replacedStrips += 1
    }

    /// Not a measured host transition: these two synthetic races keep the strip count and
    /// Aux 1 receiver unchanged while invalidating the source binding acquired before the opener.
    /// This is separate from the measured post-terminal replacement and its counter above.
    private func driftSourceAtOpener(_ drift: R2SourcePopupDrift) {
        switch drift {
        case .reordered:
            strips.swapAt(0, 2)
        case .replaced:
            let old = strips[0]
            invalidated.insert(id(old))
            for child in stripChildren[id(old)] ?? [] { invalidated.insert(id(child)) }
            strips[0] = strip(output: resultLabel[id(rootEcho)], input: options.sourceInput,
                              inputHelp: options.sourceInputHelp).0
        }
        // Capture before any terminal action can replace the strip at the old ordinal.
        sourceOpenerStripSnapshot = strips
        sourceOpenerDrifts += 1
    }

    /// Aux 1 takes another input while the popup is open. Whether Logic relabels the slot or
    /// replaces the strip's elements is not measured, so both are modelled.
    private func reassignAuxInput(to input: String) {
        auxInputNow = input
        let aux = strips[1]
        switch options.auxChange {
        case .inPlace:
            b.setAttribute(stripChildren[id(aux)]![0], kAXDescriptionAttribute as String, input)
        case .replaced:
            invalidated.insert(id(aux))
            for child in stripChildren[id(aux)] ?? [] { invalidated.insert(id(child)) }
            strips[1] = strip(output: options.auxOutput ?? options.language.stereoOutput, input: input,
                              send: options.auxSend).0
        }
    }

    private func item(_ title: String, result: String? = nil, submenu: [AXUIElement]? = nil) -> AXUIElement {
        let item = make(role: kAXMenuItemRole as String)
        b.setAttribute(item, kAXTitleAttribute as String, title)
        b.setAttribute(item, kAXEnabledAttribute as String, true)
        if let submenu {
            let menu = make(role: kAXMenuRole as String)
            b.setChildren(menu, submenu)
            b.setChildren(item, [menu])
        }
        if let result { resultLabel[id(item)] = result }
        return item
    }

    private func buildPopup(current: String) {
        let language = options.language
        // Measured: the root's checked entry echoes the current output, and a bus that an aux takes
        // is drawn with the aux's name.
        let echoTitle: String
        if case .bus(1) = options.current { echoTitle = "\(language.bus(1)) \u{2192} Aux 1" } else { echoTitle = current }
        rootEcho = item(echoTitle, result: current)
        submenuStereoOutput = item(language.stereoOutput, result: language.stereoOutput)
        pair34 = item(language.pair34, result: language.pair34)
        busOne = item("\(language.bus(1)) \u{2192} Aux 1", result: language.bus(1))
        var outputItems = [submenuStereoOutput!]
        if options.duplicateSubmenuStereoOutput {
            outputItems.append(item(language.stereoOutput, result: language.stereoOutput))
        }
        outputItems += [
            pair34, item(language.surround), item(""),
            item(language.monoSubmenu, submenu: language.monoEntries.map { item($0, result: $0) }),
        ]
        var rootItems = [item(""), rootEcho!, item(""), item(language.noOutput, result: language.noOutput), item("")]
        rootItems.append(item(language.outputSubmenu, submenu: outputItems))
        var busItems = [busOne!]
        if options.duplicateBusOne {
            let second = item(language.bus(1), result: language.bus(1))
            if options.failingRead == .secondBusOneTitle { failingAttribute[id(second)] = kAXTitleAttribute as String }
            switch options.answeringRead {
            case .secondBusOneTitle(let status): answeringAttribute[id(second)] = (kAXTitleAttribute as String, status)
            case .secondBusOneRole(let status): answeringAttribute[id(second)] = (kAXRoleAttribute as String, status)
            case nil: break
            }
            secondBusOne = second
            busItems.append(second)
        }
        busItems += (2...3).map { item(language.bus($0), result: language.bus($0)) }
        let nested = item("33 - 64", submenu: [item(language.bus(33), result: language.bus(33))])
        if options.failingRead == .nestedBusItemChildren { failingChildren.insert(id(nested)) }
        busItems.append(nested)
        rootItems.append(item(language.busSubmenu, submenu: busItems))
        rootItems += [item(""), item(language.pan)]
        if let untitled = options.untitledRootItem {
            let entry = make(role: kAXMenuItemRole as String)
            answeringAttribute[id(entry)] = (kAXTitleAttribute as String, r2NoValue)
            let field = make(role: kAXTextFieldRole as String)
            b.setChildren(field, [make(role: kAXButtonRole as String)])
            var children = [field]
            if untitled == .withSubmenu {
                let menu = make(role: kAXMenuRole as String)
                b.setChildren(menu, [item(language.bus(9), result: language.bus(9))])
                children.append(menu)
            }
            b.setChildren(entry, children)
            untitledRootEntry = entry
            rootItems.insert(entry, at: 0)
        }
        root = make(role: kAXMenuRole as String)
        b.setChildren(root, rootItems)
    }

    private func press(_ element: AXUIElement, _ action: String) -> Bool {
        lock.withLock {
            let pressed = id(element)
            pressLog.append(pressed)
            if pressed == id(outputButton) {
                menuOpen = true
                if let drift = options.sourceDriftWhilePopupOpen { driftSourceAtOpener(drift) }
                if let input = options.auxInputWhilePopupOpen { reassignAuxInput(to: input) }
                if options.stripAddedWhilePopupOpen { strips.append(make(role: kAXLayoutItemRole as String)) }
                if options.menuAppearsUnderMixer { b.setChildren(mixer, strips + [root]) }
                // Measured: the press that opens the popup reports -25204 while the menu is up.
                return false
            }
            guard menuOpen, let label = resultLabel[pressed] else { return true }
            menuOpen = false
            switch options.afterPress {
            case .applies: replaceAudioStrip(output: label)
            case .doesNothing: break
            case .slotGoesBlank: replaceAudioStrip(output: "")
            }
            b.setChildren(mixer, strips)
            let busWithoutReceiver = label.hasPrefix(options.language.busWord) && label != auxInputNow
            if options.alwaysCreatesStrip || busWithoutReceiver {
                strips.append(make(role: kAXLayoutItemRole as String))
                b.setChildren(mixer, strips)
            }
            return true
        }
    }

    private func windows() -> [[String: Any]]? {
        lock.withLock {
            var rows: [[String: Any]] = [[
                kCGWindowOwnerPID as String: NSNumber(value: r2PID),
                kCGWindowNumber as String: NSNumber(value: 29_100),
                kCGWindowLayer as String: NSNumber(value: 0),
            ]]
            if menuOpen {
                rows.append([
                    kCGWindowOwnerPID as String: NSNumber(value: r2PID),
                    kCGWindowNumber as String: NSNumber(value: 29_101),
                    kCGWindowLayer as String: NSNumber(value: 101),
                ])
            }
            return rows
        }
    }

    private func escape() {
        lock.withLock {
            escapes += 1
            if menuOpen {
                menuOpen = false
                b.setChildren(mixer, strips)
            }
        }
    }
}

private func runChannel(
    _ fixture: R2Fixture,
    destination: OutputAssignment,
    expected: OutputAssignment? = nil
) async throws -> [String: Any] {
    var params = ["index": "0", "destination": destination.token]
    if let expected { params["expected_current"] = expected.token }
    let result = await AccessibilityChannel.setOutputVerified(
        params: params, runtime: fixture.runtime, timing: .immediate
    )
    let data = try #require(result.message.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func json(_ assignment: OutputAssignment) -> NSDictionary {
    assignment.json as NSDictionary
}

private func dictionary(_ value: Any?) -> NSDictionary? {
    value as? NSDictionary
}

// MARK: - The parse

/// Kills M01: dropping the 1...256 range check on a bus number (`bus:0`, `bus:257` would parse).
@Test("a destination round-trips through its token, and a malformed one is refused")
func outputAssignmentTokensRoundTrip() {
    for assignment: OutputAssignment in [.bus(1), .bus(256), .physical(3, 4), .stereoOutput, .noOutput] {
        #expect(OutputAssignment(token: assignment.token) == assignment)
    }
    for bad in ["bus:0", "bus:257", "physical:4-3", "physical:3", "physical:3-4-5", "bus:x", "stereo", ""] {
        #expect(OutputAssignment(token: bad) == nil, "\(bad) must not parse")
    }
    #expect(OutputAssignment.make(kind: "bus", number: 1, ports: [1, 2]).value == nil)
    #expect(OutputAssignment.make(kind: "physical", number: nil, ports: [3, 4, 5]).value == nil)
    #expect(OutputAssignment.make(kind: "no_output", number: 2, ports: nil).value == nil)
}

/// Kills M02: classifying a Bus entry's whole title instead of cutting it at the arrow Logic
/// appends; and M04: parsing a pair with R1's physical prefix, which has no German `Ausgang`.
@Test("slot descriptions classify by structure in en, ko and de", arguments: [R2PopupLanguage.en, .ko, .de])
func outputAssignmentReadsSlotDescriptions(_ language: R2PopupLanguage) {
    #expect(OutputAssignment.observed(slotLabel: language.stereoOutput) == .stereoOutput)
    #expect(OutputAssignment.observed(slotLabel: language.noOutput) == .noOutput)
    #expect(OutputAssignment.observed(slotLabel: language.bus(1)) == .bus(1))
    #expect(OutputAssignment.observed(slotLabel: language.pair34) == .physical(3, 4))
    // A mono entry is not a pair, and a submenu title alone is nothing.
    #expect(OutputAssignment.observed(slotLabel: language.monoEntries[0]) == nil)
    #expect(OutputAssignment.observed(slotLabel: language.outputSubmenu) == nil)
    // The receiver suffix Logic appends at run time is cut at the arrow before classifying.
    #expect(OutputAssignment.busNumber(ofMenuItemTitle: "\(language.bus(1)) \u{2192} Aux 1") == 1)
    #expect(OutputAssignment.busNumber(ofMenuItemTitle: language.bus(12)) == 12)
    #expect(OutputAssignment.busNumber(ofMenuItemTitle: "33 - 64") == nil)
}

// MARK: - State A

/// Kills M03 (red-on-revert): removing the entry press. The slot then never changes and the
/// after-read says so, State B. And M21: re-reading the slot element held from before the press,
/// which Logic has replaced by then, so it answers -25202 and the reply is State B.
@Test("Audio 1 to Bus 1 reads back Bus 1 with the strip count unchanged")
func outputAssignmentBusSetsAndReadsBack() async throws {
    let fixture = R2Fixture()
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "A")
    #expect(dictionary(envelope["before"]) == json(.stereoOutput))
    #expect(dictionary(envelope["after"]) == json(.bus(1)))
    let changed = try #require(envelope["changed"] as? Bool)
    #expect(changed)
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(written)
    #expect(envelope["strip_count_before"] as? Int == 3)
    #expect(envelope["strip_count_after"] as? Int == 3)
    #expect(envelope["bus_receivers"] as? [Int] == [1])
    // The seam fired: the bus was checked again with the popup open, and still had its receiver.
    #expect(envelope["bus_receivers_at_press"] as? [Int] == [1])
    #expect(envelope["menu_path"] as? [String] == ["Bus", "Bus 1 \u{2192} Aux 1"])
    #expect(envelope["popup_menu_state"] as? String == "closed")
    #expect(envelope["verify_source"] as? String == "ax_output_slot")
    #expect(fixture.presses == [fixture.id(fixture.outputButton), fixture.id(fixture.busOne)])
    #expect(fixture.escapeCount == 0)
    // The seam fired: the slot that was pressed is gone, so the read-back came from the new strip.
    #expect(fixture.stripsReplaced == 1)
    let pressedSlotGone = fixture.isGone(fixture.outputButton)
    #expect(pressedSlotGone)
}

/// `Stereo Output` is taken from the Output submenu. The root's checked entry echoes the current
/// output (here the pair), so once the output is not Stereo Output the root has none. Kills M05:
/// looking for `Stereo Output` at the root, which refuses destination_not_offered (the defect the
/// first live run hit in ko and de); and M04: parsing pairs with R1's physical prefix, which reads
/// no `Ausgang 3-4`.
@Test("a physical pair sets and Stereo Output restores, by parent, in en, ko and de",
      arguments: [R2PopupLanguage.en, .ko, .de])
func outputAssignmentPhysicalSetsAndRestores(_ language: R2PopupLanguage) async throws {
    let set = R2Fixture(.init(language: language))
    let setEnvelope = try await runChannel(set, destination: .physical(3, 4))
    #expect(setEnvelope["state"] as? String == "A")
    #expect(dictionary(setEnvelope["after"]) == json(.physical(3, 4)))
    #expect(setEnvelope["menu_path"] as? [String] == [language.outputSubmenu, language.pair34])
    #expect(set.presses.last == set.id(set.pair34))

    let restore = R2Fixture(.init(language: language, current: .label(language.pair34)))
    let restoreEnvelope = try await runChannel(restore, destination: .stereoOutput, expected: .physical(3, 4))
    #expect(restoreEnvelope["state"] as? String == "A")
    #expect(dictionary(restoreEnvelope["before"]) == json(.physical(3, 4)))
    #expect(dictionary(restoreEnvelope["after"]) == json(.stereoOutput))
    #expect(restoreEnvelope["menu_path"] as? [String] == [language.outputSubmenu, language.stereoOutput])
    #expect(restore.presses.last == restore.id(restore.submenuStereoOutput))
    #expect(!restore.presses.contains(restore.id(restore.rootEcho)))
}

/// Kills M06: dropping the equal-already check, which opens the popup and presses anyway.
@Test("a destination already in place is State A changed:false with nothing pressed")
func outputAssignmentNoOpPressesNothing() async throws {
    let fixture = R2Fixture(.init(current: .bus(1)))
    let envelope = try await runChannel(fixture, destination: .bus(1), expected: .bus(1))

    #expect(envelope["state"] as? String == "A")
    let changed = try #require(envelope["changed"] as? Bool)
    #expect(!changed)
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(!written)
    #expect(fixture.presses.isEmpty)
}

// MARK: - Refusals before any press

/// Kills M07: reading an unreadable current output as "not equal" and pressing anyway.
@Test("an unreadable current output refuses, nothing pressed")
func outputAssignmentRefusesAnUnreadableCurrentOutput() async throws {
    let fixture = R2Fixture(.init(current: .blank))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "readback_unavailable")
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(!written)
    #expect(fixture.presses.isEmpty)
}

/// Kills M07: an unclassifiable label read as "not equal" and pressed past.
@Test("a current output this cannot classify refuses, nothing pressed")
func outputAssignmentRefusesAnUnclassifiableCurrentOutput() async throws {
    let fixture = R2Fixture(.init(current: .label("Surround")))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "readback_unavailable")
    #expect(envelope["observed_label"] as? String == "Surround")
    #expect(fixture.presses.isEmpty)
}

/// Kills M08: ignoring `expected_current`.
@Test("expected_current that differs from the observed output refuses, nothing pressed")
func outputAssignmentRefusesAStaleExpectation() async throws {
    let fixture = R2Fixture()
    let envelope = try await runChannel(fixture, destination: .bus(1), expected: .physical(3, 4))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "stale_snapshot")
    #expect(dictionary(envelope["before"]) == json(.stereoOutput))
    #expect(dictionary(envelope["expected_current"]) == json(.physical(3, 4)))
    #expect(fixture.presses.isEmpty)
}

/// Kills M09: dropping the receiver check. The press then lands on a bus nothing receives, the
/// fixture adds an aux as Logic does, and the reply is a side effect instead of a clean refusal.
@Test("a bus no other strip receives refuses bus_has_no_receiver, nothing pressed")
func outputAssignmentRefusesABusWithoutReceiver() async throws {
    let fixture = R2Fixture()
    let envelope = try await runChannel(fixture, destination: .bus(2))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "bus_has_no_receiver")
    #expect(envelope["bus"] as? Int == 2)
    // The Stereo Out strip was read whole and has no input slot. That is an answer, not a gap.
    #expect(envelope["strips_with_input_not_read"] as? [Int] == [])
    #expect(envelope["strip_count_before"] as? Int == 3)
    #expect(fixture.presses.isEmpty)
}

enum R2ReceiverChange: String, CaseIterable, Sendable { case inPlace, replaced }

/// Kills M32: checking the bus only before the popup opens. Aux 1, Bus 1's only receiver, takes
/// another input while the popup is up, so the press would land on a bus nothing receives and the
/// fixture would add an aux, as Logic does.
@Test("a receiver reassigned while the popup is open refuses bus_has_no_receiver, nothing selected",
      arguments: R2ReceiverChange.allCases)
func outputAssignmentRechecksTheBusAtThePress(_ change: R2ReceiverChange) async throws {
    let fixture = R2Fixture(.init(auxInputWhilePopupOpen: "Input 2", auxChange: change))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "bus_has_no_receiver")
    let readWithPopupOpen = try #require(envelope["read_with_popup_open"] as? Bool)
    #expect(readWithPopupOpen)
    // Before the popup opened, Aux 1 at index 1 was Bus 1's receiver.
    #expect(envelope["bus_receivers"] as? [Int] == [1])
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(!written)
    #expect(envelope["popup_menu_state"] as? String == "dismissed")
    #expect(fixture.escapeCount == 1)
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
    #expect(fixture.strips.count == 3)
}

/// Kills M33: rechecking the bus without comparing the strip count. A strip added while the popup is
/// open can shift what an ordinal names, so the strips are not checked again by ordinal: it refuses.
@Test("a strip count that moved while the popup is open refuses, nothing selected")
func outputAssignmentRechecksTheStripCountAtThePress() async throws {
    let fixture = R2Fixture(.init(stripAddedWhilePopupOpen: true))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "unsupported_state")
    let readWithPopupOpen = try #require(envelope["read_with_popup_open"] as? Bool)
    #expect(readWithPopupOpen)
    #expect(envelope["strip_count_at_press"] as? Int == 4)
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(!written)
    #expect(envelope["popup_menu_state"] as? String == "dismissed")
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
}

/// #291/#967 primitive prerequisite only: a same-count source reorder/replacement must not
/// validate another strip at the original ordinal and then select the held source's popup entry.
/// The original receiver stays in place; no lifecycle allocation or post-terminal identity is
/// qualified by these synthetic opener races.
@Test("same-count source drift while the output popup opens refuses before terminal selection",
      arguments: R2SourcePopupDrift.allCases)
private func outputAssignmentRefusesSourceDriftWhilePopupOpens(_ drift: R2SourcePopupDrift) async throws {
    var options = R2Fixture.Options()
    options.sourceDriftWhilePopupOpen = drift
    let fixture = R2Fixture(options)
    let originalSource = try #require(fixture.strips.first)
    let originalReceiver = fixture.strips[1]
    let originalThird = fixture.strips[2]
    let originalOutput = try #require(fixture.outputButton)

    let envelope = try await runChannel(fixture, destination: .bus(1))

    // Establish the actual seam fired without growing the population or replacing the receiver.
    let openerStrips = try #require(fixture.stripsAtSourceOpenerDrift)
    try #require(openerStrips.count == 3)
    #expect(fixture.sourceOpenerDriftCount == 1)
    #expect(fixture.strips.count == 3)
    #expect(envelope["strip_count_before"] as? Int == 3)
    #expect(envelope["bus_receivers"] as? [Int] == [1])
    #expect(CFEqual(openerStrips[1], originalReceiver))
    #expect(!CFEqual(openerStrips[0], originalSource))
    switch drift {
    case .reordered:
        #expect(CFEqual(openerStrips[0], originalThird))
        #expect(CFEqual(openerStrips[2], originalSource))
        #expect(!fixture.isGone(originalSource))
    case .replaced:
        #expect(fixture.isGone(originalSource))
        #expect(fixture.isGone(originalOutput))
    }

    #expect(envelope["state"] as? String == "C")
    // Same-count binding drift belongs to the adapter's existing unsupported-state refusal.
    #expect(envelope["error"] as? String == "unsupported_state")
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(!written)
    #expect(envelope["popup_menu_state"] as? String == "dismissed")
    #expect(fixture.escapeCount == 1)
    #expect(fixture.presses == [fixture.id(originalOutput)])
    #expect(fixture.presses.filter { $0 == fixture.id(fixture.busOne) }.isEmpty)
    // Opener drift must not be counted as the legitimate replacement after a selected entry.
    #expect(fixture.stripsReplaced == 0)
}

@Test("a strip whose input did not read is listed beside bus_has_no_receiver, never counted")
func outputAssignmentListsAnUnreadInputBesideTheRefusal() async throws {
    var options = R2Fixture.Options()
    options.failingRead = .thirdStripChildren
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .bus(2))

    #expect(envelope["error"] as? String == "bus_has_no_receiver")
    #expect(envelope["strips_with_input_not_read"] as? [Int] == [2])
    #expect(fixture.presses.isEmpty)
}

/// R2-01: after No Output was selected, pressing the slot opened no menu (three presses, and again
/// at 0, 5, 15 and 30 seconds), so this command could not set the strip back.
@Test("no_output is refused as a destination, nothing pressed")
func outputAssignmentRefusesNoOutputAsADestination() async throws {
    let fixture = R2Fixture()
    let envelope = try await runChannel(fixture, destination: .noOutput)

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "invalid_params")
    #expect(fixture.presses.isEmpty)
}

@Test("a strip already at No Output refuses unsupported_state, nothing pressed")
func outputAssignmentRefusesAStripAtNoOutput() async throws {
    var options = R2Fixture.Options()
    options.current = .label(R2PopupLanguage.en.noOutput)
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .stereoOutput)

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "unsupported_state")
    #expect(fixture.presses.isEmpty)
}

/// R2-02, the reviewer's topology: strip 0 receives Bus 1 and outputs Stereo Output, the aux
/// receives Bus 2 and outputs Bus 1. Both buses have a receiver, and strip 0 to Bus 2 would close
/// strip 0 → aux → strip 0.
@Test("an assignment that closes a loop through a receiver refuses routing_cycle, nothing pressed")
func outputAssignmentRefusesALoop() async throws {
    var options = R2Fixture.Options()
    options.sourceInput = R2PopupLanguage.en.bus(1)
    options.auxInput = R2PopupLanguage.en.bus(2)
    options.auxOutput = R2PopupLanguage.en.bus(1)
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .bus(2))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "routing_cycle")
    #expect(envelope["input_bus"] as? Int == 1)
    #expect(fixture.presses.isEmpty)
}

/// Strip 0 is the only reader of Bus 1 and is sent to Bus 1. No other strip receives that bus,
/// but the reason to refuse is the loop, not a missing receiver.
@Test("a strip sent to the bus it alone reads refuses routing_cycle, not bus_has_no_receiver")
func outputAssignmentRefusesASelfLoop() async throws {
    var options = R2Fixture.Options()
    options.sourceInput = R2PopupLanguage.en.bus(1)
    options.auxInput = R2PopupLanguage.en.bus(2)
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "routing_cycle")
    #expect(envelope["input_bus"] as? Int == 1)
    #expect(fixture.presses.isEmpty)
}

/// The same strip fed by Bus 1, sent to Bus 2 whose receiver goes on to Bus 3 with an empty send:
/// a chain that never reaches Bus 1 is not a loop.
@Test("a chain that does not reach the strip's input bus is not a loop, and the assignment lands")
func outputAssignmentAllowsAChainThatDoesNotLoop() async throws {
    var options = R2Fixture.Options()
    options.sourceInput = R2PopupLanguage.en.bus(1)
    options.auxInput = R2PopupLanguage.en.bus(2)
    options.auxOutput = R2PopupLanguage.en.bus(3)
    options.auxSend = .empty
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .bus(2))

    #expect(envelope["state"] as? String == "A")
    #expect(envelope["after"] as? NSDictionary == json(.bus(2)))
    #expect(envelope["bus_receivers"] as? [Int] == [1])
}

enum R2Dependency: String, CaseIterable, Sendable { case ownInput, otherInput, receiverOutput, occupiedSend }

@Test("a strip the loop check must follow that does not say where its signal goes refuses, nothing pressed",
      arguments: R2Dependency.allCases)
func outputAssignmentRefusesAnUnfollowableDependency(_ dependency: R2Dependency) async throws {
    var options = R2Fixture.Options()
    options.sourceInput = R2PopupLanguage.en.bus(1)
    options.auxInput = R2PopupLanguage.en.bus(2)
    let strip: Int
    let part: String
    switch dependency {
    case .ownInput: options.failingRead = .sourceInputRole; (strip, part) = (0, "input")
    case .otherInput: options.failingRead = .thirdStripChildren; (strip, part) = (2, "input")
    case .receiverOutput: options.auxOutput = ""; (strip, part) = (1, "output")
    case .occupiedSend: options.auxSend = .occupied; (strip, part) = (1, "send")
    }
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .bus(2))

    #expect(envelope["state"] as? String == "C")
    if dependency == .ownInput {
        // The unread role could itself be another output control. Output uniqueness therefore
        // fails before the later dependency traversal can identify this as an input failure.
        #expect(envelope["error"] as? String == "readback_unavailable")
        #expect(envelope["dependency_strip"] == nil)
        #expect(envelope["dependency_unread"] == nil)
    } else {
        #expect(envelope["error"] as? String == "routing_dependency_unknown")
        #expect(envelope["dependency_strip"] as? Int == strip)
        #expect(envelope["dependency_unread"] as? String == part)
    }
    #expect(fixture.presses.isEmpty)
}

enum R2Transport: String, CaseIterable, Sendable { case playing, recording, unreadable }

/// Kills M10: ignoring a running transport; and M11: reading an unread transport as stopped.
@Test("a running or unreadable transport refuses, nothing pressed", arguments: R2Transport.allCases)
func outputAssignmentRefusesUnlessStopped(_ transport: R2Transport) async throws {
    var options = R2Fixture.Options()
    switch transport {
    case .playing: options.play = true
    case .recording: options.play = true; options.record = true
    case .unreadable: options.record = nil
    }
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .physical(3, 4))

    #expect(envelope["state"] as? String == "C")
    switch transport {
    case .playing, .recording:
        #expect(envelope["error"] as? String == "unsupported_state")
        #expect(envelope["transport"] as? String == transport.rawValue)
    case .unreadable:
        #expect(envelope["error"] as? String == "transport_state_unknown")
    }
    #expect(fixture.presses.isEmpty)
}

// MARK: - Refusals with the popup open

/// Kills M12: matching any pair the Output submenu lists instead of the requested ports.
@Test("ports the popup does not offer refuse with what it does offer, nothing selected")
func outputAssignmentRefusesMissingPorts() async throws {
    let fixture = R2Fixture()
    let envelope = try await runChannel(fixture, destination: .physical(5, 6))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "element_not_found")
    #expect(envelope["menu_failure"] as? String == "destination_not_offered")
    #expect(envelope["offered"] as? [String] == ["physical:3-4"])
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(!written)
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
    #expect(envelope["popup_menu_state"] as? String == "dismissed")
}

enum R2Repeat: String, CaseIterable, Sendable { case stereoOutput, busOne }

/// Kills M13: first match. Two entries with the same meaning under the same parent cannot be
/// told apart, and pressing either would be a guess.
@Test("a title repeated under one parent refuses, nothing selected", arguments: R2Repeat.allCases)
func outputAssignmentRefusesARepeatedTitle(_ repeated: R2Repeat) async throws {
    var options = R2Fixture.Options()
    let destination: OutputAssignment
    switch repeated {
    case .stereoOutput:
        options.duplicateSubmenuStereoOutput = true
        options.current = .label("Output 3-4")
        destination = .stereoOutput
    case .busOne:
        options.duplicateBusOne = true
        destination = .bus(1)
    }
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: destination)

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "ambiguous_target_name")
    #expect(envelope["menu_failure"] as? String == "destination_title_repeated")
    #expect(envelope["matching_entries"] as? Int == 2)
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
}

enum R2MenuRead: String, CaseIterable, Sendable { case secondTitle, nestedSubmenu }

/// R2-03: an entry whose title or submenu did not read could be the second of two, so passing it
/// over would make the other look unique. The Bus submenu was not read whole; nothing is selected.
@Test("a menu entry whose title or submenu did not read refuses menu_not_read, nothing selected",
      arguments: R2MenuRead.allCases)
func outputAssignmentRefusesAMenuNotReadWhole(_ read: R2MenuRead) async throws {
    var options = R2Fixture.Options()
    switch read {
    case .secondTitle:
        options.duplicateBusOne = true
        options.failingRead = .secondBusOneTitle
    case .nestedSubmenu:
        options.failingRead = .nestedBusItemChildren
    }
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "element_not_found")
    #expect(envelope["menu_failure"] as? String == "menu_not_read")
    #expect(envelope["menu_path"] as? [String] == [options.language.busSubmenu])
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
}

/// Reads `attribute` through the production status seam and returns the AX status it answered, or
/// nil when it read. Proves a fixture reaches the status path, not the builder's success-and-nil.
private func r2AnsweredStatus(
    _ fixture: R2Fixture, _ element: AXUIElement, _ attribute: String
) -> Int32? {
    let read: Result<String?, AXHelpers.AXStatusError> =
        AXHelpers.getAttributeResult(element, attribute, runtime: fixture.runtime.ax)
    guard case let .failure(error) = read else { return nil }
    return error.raw
}

enum R2AnsweredItemRead: String, CaseIterable, Sendable {
    case titleNoValue, titleAttributeUnsupported, roleNoValue, roleAttributeUnsupported
}

/// #1062 review R2-03: an entry whose title or role ANSWERS "none" (-25212, -25205) has no
/// identity that was read, so it could be the second of two `Bus 1` entries. Passing it over would
/// make the first look unique and pressable. The Bus submenu is not read whole; nothing is selected.
@Test("a menu entry whose title or role answers none refuses menu_not_read, nothing selected",
      arguments: R2AnsweredItemRead.allCases)
func outputAssignmentRefusesAnEntryWhoseIdentityAnswersNone(_ read: R2AnsweredItemRead) async throws {
    var options = R2Fixture.Options()
    options.duplicateBusOne = true
    let status: AXHelpers.AXStatusError
    let attribute: String
    switch read {
    case .titleNoValue: (status, attribute) = (r2NoValue, kAXTitleAttribute as String)
    case .titleAttributeUnsupported: (status, attribute) = (r2AttributeUnsupported, kAXTitleAttribute as String)
    case .roleNoValue: (status, attribute) = (r2NoValue, kAXRoleAttribute as String)
    case .roleAttributeUnsupported: (status, attribute) = (r2AttributeUnsupported, kAXRoleAttribute as String)
    }
    options.answeringRead = attribute == (kAXTitleAttribute as String)
        ? .secondBusOneTitle(status) : .secondBusOneRole(status)
    let fixture = R2Fixture(options)
    let second = try #require(fixture.secondBusOne)
    // The seam fired: the entry answers the injected status, not the builder's success-and-nil.
    let answered = try #require(r2AnsweredStatus(fixture, second, attribute))
    #expect(answered == status.raw)

    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "element_not_found")
    #expect(envelope["menu_failure"] as? String == "menu_not_read")
    #expect(envelope["menu_path"] as? [String] == [options.language.busSubmenu])
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
}

/// Positive control for R2-03, the shape measured on Logic 12.3 ko (2026-09-29): the root's first
/// entry answers -25212 for its title and holds one AXTextField, the popup's search field. It is
/// passed over, and a unique `Bus 1` entry is still pressed.
@Test("an untitled root entry holding only the search field is passed over, and the bus entry is pressed")
func outputAssignmentPassesOverTheSearchFieldEntry() async throws {
    var options = R2Fixture.Options()
    options.untitledRootItem = .searchField
    let fixture = R2Fixture(options)
    let entry = try #require(fixture.untitledRootEntry)
    let answered = try #require(r2AnsweredStatus(fixture, entry, kAXTitleAttribute as String))
    #expect(answered == r2NoValue.raw)

    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "A")
    #expect(dictionary(envelope["after"]) == json(.bus(1)))
    #expect(fixture.presses == [fixture.id(fixture.outputButton), fixture.id(fixture.busOne)])
}

/// An untitled entry that also holds a submenu is not the search field: it could be an entry, so
/// the root is not read whole and nothing is selected.
@Test("an untitled root entry that holds a submenu refuses menu_not_read, nothing selected")
func outputAssignmentRefusesAnUntitledEntryWithASubmenu() async throws {
    var options = R2Fixture.Options()
    options.untitledRootItem = .withSubmenu
    let fixture = R2Fixture(options)
    let entry = try #require(fixture.untitledRootEntry)
    let answered = try #require(r2AnsweredStatus(fixture, entry, kAXTitleAttribute as String))
    #expect(answered == r2NoValue.raw)

    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["menu_failure"] as? String == "menu_not_read")
    #expect(envelope["menu_path"] as? [String] == [])
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
}

/// #1062 review R2-02, the reviewer's refusal witness: the source strip is fed by Bus 1, but its
/// input slot's help is wording the LabelSet does not know. Bus 2's receiver outputs Bus 1, so
/// Bus 2 would close a loop. Reading that strip as "no input slot" would clear the loop check and
/// press; its input is unknown instead, and the assignment is refused before anything is pressed.
@Test("a source whose input slot help is unrecognised but names a bus refuses routing_dependency_unknown")
func outputAssignmentRefusesAnUnrecognisedInputThatNamesABus() async throws {
    var options = R2Fixture.Options()
    options.sourceInput = R2PopupLanguage.en.bus(1)
    options.sourceInputHelp = "Source selector. Choose what this channel strip hears."
    options.auxInput = R2PopupLanguage.en.bus(2)
    options.auxOutput = R2PopupLanguage.en.bus(1)
    let fixture = R2Fixture(options)
    let envelope = try await runChannel(fixture, destination: .bus(2))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "routing_dependency_unknown")
    #expect(envelope["dependency_strip"] as? Int == 0)
    #expect(envelope["dependency_unread"] as? String == "input")
    #expect(fixture.presses.isEmpty)
}

// MARK: - inputSlotReading establishes absence (#1062 review R2-02)

enum R2UnknownButton: String, CaseIterable, Sendable {
    case helpUnmatchedBusDescription, helpAbsentBusDescription, helpUnmatchedOtherDescription
    case descriptionAnswersNoValue, descriptionFailsCannotComplete
}

/// One strip: an identified output slot and send slot both described as buses (never consulted),
/// a Mute button, and one button whose help names no known slot, read as `unknown` says.
private func r2InputReadingStrip(
    unknown: R2UnknownButton?, recognisedInputAfter: String? = nil
) -> (AXUIElement, AXHelpers.Runtime) {
    let b = FakeAXRuntimeBuilder()
    var nextID = 29_130_000
    func make(_ role: String, help: String?, description: String?) -> AXUIElement {
        nextID += 1
        let element = b.element(nextID)
        b.setAttribute(element, kAXRoleAttribute as String, role)
        if let help { b.setAttribute(element, kAXHelpAttribute as String, help) }
        if let description { b.setAttribute(element, kAXDescriptionAttribute as String, description) }
        return element
    }
    let strip = make(kAXLayoutItemRole as String, help: nil, description: nil)
    var children = [
        make(kAXButtonRole as String, help: "Mute button. Mutes the channel strip.", description: "Mute"),
        make(kAXButtonRole as String, help: "Send slot. Click to choose a send destination.", description: "Bus 4"),
        make(kAXButtonRole as String, help: "Output slot. Click and hold to choose the channel strip output.",
             description: "Bus 3"),
    ]
    var failingID: Int?
    var failingStatus = r2CannotComplete
    if let unknown {
        let help: String? = unknown == .helpAbsentBusDescription ? nil : "Source selector. Choose what this strip hears."
        let description: String? = unknown == .helpUnmatchedOtherDescription ? "Library indicator" : "Bus 1"
        let button = make(kAXButtonRole as String, help: help, description: description)
        switch unknown {
        case .descriptionAnswersNoValue: (failingID, failingStatus) = (b.elementID(button), r2NoValue)
        case .descriptionFailsCannotComplete: (failingID, failingStatus) = (b.elementID(button), r2CannotComplete)
        default: break
        }
        children.append(button)
    }
    if let recognisedInputAfter {
        children.append(make(kAXButtonRole as String, help: "Input slot. Click and hold to choose the channel strip input.",
                             description: recognisedInputAfter))
    }
    b.setChildren(strip, children)
    let runtime = b.makeAXRuntime(
        attributeValueResultHandler: { [failingID, failingStatus, b] element, attribute in
            guard let failingID, attribute == kAXDescriptionAttribute as String,
                  b.elementID(element) == failingID else { return nil }
            return .failure(failingStatus)
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    return (strip, runtime)
}

@Test("inputSlotReading: a button whose help names no known slot decides by its description",
      arguments: R2UnknownButton.allCases)
func inputSlotReadingEstablishesAbsence(_ unknown: R2UnknownButton) throws {
    let (strip, runtime) = r2InputReadingStrip(unknown: unknown)
    let reading = AXLogicProElements.inputSlotReading(in: strip, runtime: runtime)
    switch unknown {
    case .helpUnmatchedBusDescription, .helpAbsentBusDescription, .descriptionFailsCannotComplete:
        #expect(reading == .unreadable)
    case .helpUnmatchedOtherDescription, .descriptionAnswersNoValue:
        #expect(reading == .noSlot)
    }
}

/// The control: a strip whose buttons are all identified slots or ordinary controls reads
/// `.noSlot`, although its output and send slots are described as buses.
@Test("inputSlotReading: identified slots and ordinary buttons still read noSlot")
func inputSlotReadingNoSlotWithOnlyIdentifiedButtons() throws {
    let (strip, runtime) = r2InputReadingStrip(unknown: nil)
    #expect(AXLogicProElements.inputSlotReading(in: strip, runtime: runtime) == .noSlot)
}

/// An unidentified bus button may be another input. A recognised slot cannot make the
/// existing output writer's loop precheck treat that competing possibility as a known route.
@Test("inputSlotReading: an unidentified bus button remains unknown beside a recognised slot")
func inputSlotReadingRecognisedSlotStillDecides() throws {
    let (strip, runtime) = r2InputReadingStrip(unknown: .helpUnmatchedBusDescription, recognisedInputAfter: "Bus 2")
    #expect(AXLogicProElements.inputSlotReading(in: strip, runtime: runtime) == .unreadable)
}

/// Kills M14: skipping the cleanup when no menu appears under the Mixer. The press still put a
/// popup-level window up, which would stay open and wedge Logic's AppleEvents.
@Test("a slot press whose popup is not under the Mixer refuses, and the popup is dismissed")
func outputAssignmentRefusesWhenNoPopupOpens() async throws {
    let fixture = R2Fixture(.init(menuAppearsUnderMixer: false))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["menu_failure"] as? String == "popup_not_opened")
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(!written)
    #expect(envelope["popup_menu_state"] as? String == "dismissed")
    #expect(fixture.escapeCount == 1)
    #expect(fixture.presses == [fixture.id(fixture.outputButton)])
}

// MARK: - After the press

/// Kills M15: treating an unreadable after-read as "not equal" (it would say readback_mismatch).
@Test("an after-read that fails is State B readback_unavailable")
func outputAssignmentLostAfterReadIsStateB() async throws {
    let fixture = R2Fixture(.init(afterPress: .slotGoesBlank))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(written)
    #expect(envelope["after"] is NSNull)
}

/// Kills M16: trusting the request. The press lands and the slot still reads Stereo Output.
@Test("an after-read that disagrees is State B readback_mismatch")
func outputAssignmentMismatchedAfterReadIsStateB() async throws {
    let fixture = R2Fixture(.init(afterPress: .doesNothing))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_mismatch")
    #expect(dictionary(envelope["after"]) == json(.stereoOutput))
    #expect(envelope["observed_label"] as? String == "Stereo Output")
}

/// Kills M17: ignoring the strip count after the press. Once the count moved the ordinal may name
/// another strip, so no output is read back from it.
@Test("a strip count that grew is State C unexpected_side_effect strip_created, nothing cleaned up")
func outputAssignmentStripCreatedIsStateC() async throws {
    let fixture = R2Fixture(.init(alwaysCreatesStrip: true))
    let envelope = try await runChannel(fixture, destination: .bus(1))

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "unexpected_side_effect")
    #expect(envelope["unexpected_side_effect"] as? String == "strip_created")
    #expect(envelope["strip_count_before"] as? Int == 3)
    #expect(envelope["strip_count_after"] as? Int == 4)
    let written = try #require(envelope["write_attempted"] as? Bool)
    #expect(written)
    #expect(envelope["after"] is NSNull)
    // Exactly the slot and the entry: no undo, no removal.
    #expect(fixture.presses.count == 2)
}

// MARK: - Through the dispatcher

private func dispatch(
    _ fixture: R2Fixture,
    _ params: [String: Value],
    targetRegistry: TargetRegistry? = nil
) async throws -> [String: Any] {
    let channel = AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        hasVisibleWindow: { true },
        logicRuntime: fixture.runtime
    ))
    let router = ChannelRouter()
    await router.register(channel)
    let result = await MixerDispatcher.handle(
        command: "set_output_verified",
        params: params,
        router: router,
        cache: StateCache(),
        targetRegistry: targetRegistry
    )
    let data = try #require(sharedToolText(result).data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The production path: MixerDispatcher -> ChannelRouter -> AccessibilityChannel.execute ->
/// setOutputVerified, with the live timing and the live popup cleanup over the fixture.
/// Kills M18: dropping the router row (the chain is then exhausted); and M03.
@Test("the public command reaches the channel through the router and reads back")
func outputAssignmentProductionPathSetsBus() async throws {
    let fixture = R2Fixture()
    let envelope = try await dispatch(fixture, [
        "track": .int(0),
        "destination": .object(["kind": .string("bus"), "number": .int(1)]),
        "expected_current": .object(["kind": .string("stereo_output")]),
    ])

    #expect(envelope["state"] as? String == "A")
    #expect(envelope["operation"] as? String == "mixer.set_output_verified")
    #expect(dictionary(envelope["after"]) == json(.bus(1)))
    #expect(fixture.presses == [fixture.id(fixture.outputButton), fixture.id(fixture.busOne)])
}

/// Kills M19: an unresolved reference falling back to strip 0.
@Test("a target_ref that does not resolve refuses before the channel")
func outputAssignmentRefusesAnUnresolvedReference() async throws {
    let fixture = R2Fixture()
    let envelope = try await dispatch(fixture, [
        "target_ref": .string("trk_0000000000000000"),
        "destination": .object(["kind": .string("bus"), "number": .int(1)]),
    ], targetRegistry: TargetRegistry())

    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "stale_target_reference")
    #expect(fixture.presses.isEmpty)
}

/// Kills M20: ignoring an unknown key. A localized `label` next to a valid `{kind, number}` must be
/// refused, not dropped: D2 keeps every localized string out of the parameters.
@Test("a destination that is not {kind, number|ports} is invalid_params, nothing routed")
func outputAssignmentRefusesMalformedDestinations() async throws {
    let malformed: [Value] = [
        .object(["kind": .string("bus"), "number": .int(1), "label": .string("Bus 1")]),
        .string("Bus 1"),
        .object(["kind": .string("bus"), "number": .int(1), "ports": .array([.int(1), .int(2)])]),
        .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4), .int(5)])]),
        .object(["kind": .string("bus"), "numbr": .int(1)]),
        .object(["kind": .string("aux"), "number": .int(1)]),
    ]
    for destination in malformed {
        let fixture = R2Fixture()
        let envelope = try await dispatch(fixture, ["track": .int(0), "destination": destination])
        #expect(envelope["error"] as? String == "invalid_params", "\(destination)")
        #expect(fixture.presses.isEmpty)
    }
}
