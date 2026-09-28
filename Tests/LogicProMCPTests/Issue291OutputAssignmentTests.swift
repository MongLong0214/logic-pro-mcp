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

private final class R2Fixture: @unchecked Sendable {
    enum CurrentOutput { case stereo, bus(Int), label(String), blank }
    enum AfterPress { case applies, doesNothing, slotGoesBlank }

    struct Options {
        var language = R2PopupLanguage.en
        var current = CurrentOutput.stereo
        var auxInput: String?
        var afterPress = AfterPress.applies
        /// Logic adds an aux for a bus no strip receives; `always` makes any press add one.
        var alwaysCreatesStrip = false
        var play: Bool? = false
        var record: Bool? = false
        var duplicateSubmenuStereoOutput = false
        var duplicateBusOne = false
        /// False: the press puts a popup-level window up, but no AXMenu appears under the Mixer.
        var menuAppearsUnderMixer = true
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
    private var replacedStrips = 0

    private(set) var app: AXUIElement!
    private(set) var mixer: AXUIElement!
    private(set) var strips: [AXUIElement] = []
    private(set) var outputButton: AXUIElement!
    private(set) var root: AXUIElement!
    private(set) var rootEcho: AXUIElement!
    private(set) var submenuStereoOutput: AXUIElement!
    private(set) var busOne: AXUIElement!
    private(set) var pair34: AXUIElement!

    init(_ options: Options = Options()) {
        self.options = options
        let language = options.language
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
        let (audio, audioOutput) = strip(output: current, input: "Input 1")
        outputButton = audioOutput
        let (aux, _) = strip(output: language.stereoOutput, input: options.auxInput ?? language.bus(1))
        let (stereoOut, _) = strip(output: nil, input: nil)
        strips = [audio, aux, stereoOut]
        b.setChildren(mixer, strips)
        b.setChildren(window, [controlBar, mixer])
        buildPopup(current: current)
    }

    var runtime: AXLogicProElements.Runtime {
        let base = b.makeLogicRuntime(
            pid: r2PID,
            appElement: app,
            attributeValueHandler: { [self] element, _ -> AnyObject?? in isGone(element) ? .some(nil) : .none },
            attributeValueResultHandler: { [self] element, _ in isGone(element) ? .failure(r2InvalidElement) : nil },
            childrenHandler: { [self] element in isGone(element) ? [] : nil },
            childrenResultHandler: { [self] element in isGone(element) ? .failure(r2InvalidElement) : nil },
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
    func id(_ element: AXUIElement) -> Int { b.elementID(element) }
    func isGone(_ element: AXUIElement) -> Bool { lock.withLock { invalidated.contains(id(element)) } }

    private func make(role: String? = nil, description: String? = nil) -> AXUIElement {
        nextID += 1
        let element = b.element(nextID)
        if let role { b.setAttribute(element, kAXRoleAttribute as String, role) }
        if let description { b.setAttribute(element, kAXDescriptionAttribute as String, description) }
        return element
    }

    private func strip(output: String?, input: String?) -> (AXUIElement, AXUIElement?) {
        let strip = make(role: kAXLayoutItemRole as String)
        var children: [AXUIElement] = []
        var outputSlot: AXUIElement?
        if let input {
            let slot = make(role: kAXButtonRole as String, description: input)
            b.setAttribute(slot, kAXHelpAttribute as String, "Input slot. Click and hold to choose the channel strip input.")
            children.append(slot)
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
        strips[0] = strip(output: output, input: "Input 1").0
        replacedStrips += 1
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
            busItems.append(item(language.bus(1), result: language.bus(1)))
        }
        busItems += (2...3).map { item(language.bus($0), result: language.bus($0)) }
        busItems.append(item("33 - 64", submenu: [item(language.bus(33), result: language.bus(33))]))
        rootItems.append(item(language.busSubmenu, submenu: busItems))
        rootItems += [item(""), item(language.pan)]
        root = make(role: kAXMenuRole as String)
        b.setChildren(root, rootItems)
    }

    private func press(_ element: AXUIElement, _ action: String) -> Bool {
        lock.withLock {
            let pressed = id(element)
            pressLog.append(pressed)
            if pressed == id(outputButton) {
                menuOpen = true
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
            let receivedBus = options.auxInput ?? options.language.bus(1)
            let busWithoutReceiver = label.hasPrefix(options.language.busWord) && label != receivedBus
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
    // The Stereo Out strip has no input slot: listed, not counted as "not a receiver".
    #expect(envelope["strips_with_input_not_read"] as? [Int] == [2])
    #expect(envelope["strip_count_before"] as? Int == 3)
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
