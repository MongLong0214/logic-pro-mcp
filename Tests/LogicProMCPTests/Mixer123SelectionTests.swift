@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private let axLayoutAreaRole = "AXLayoutArea"

private struct Mixer123Fixture {
    let runtime: AXLogicProElements.Runtime
    let layoutArea: AXUIElement
    let strips: [AXUIElement]
}

private func axPoint(_ x: CGFloat, _ y: CGFloat) -> AXValue {
    var point = CGPoint(x: x, y: y)
    return AXValueCreate(.cgPoint, &point)!
}

private func axSize(_ width: CGFloat, _ height: CGFloat) -> AXValue {
    var size = CGSize(width: width, height: height)
    return AXValueCreate(.cgSize, &size)!
}

private func setFrame(
    _ builder: FakeAXRuntimeBuilder,
    _ element: AXUIElement,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
) {
    builder.setAttribute(element, kAXPositionAttribute as String, axPoint(x, y))
    builder.setAttribute(element, kAXSizeAttribute as String, axSize(width, height))
}

private func setRole(
    _ builder: FakeAXRuntimeBuilder,
    _ element: AXUIElement,
    _ role: String
) {
    builder.setAttribute(element, kAXRoleAttribute as String, role)
}

private func setNamedContainer(
    _ builder: FakeAXRuntimeBuilder,
    _ element: AXUIElement,
    role: String,
    description: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
) {
    setRole(builder, element, role)
    builder.setAttribute(element, kAXDescriptionAttribute as String, description)
    setFrame(builder, element, x: x, y: y, width: width, height: height)
}

private func setButton(
    _ builder: FakeAXRuntimeBuilder,
    _ element: AXUIElement,
    description: String? = nil,
    title: String? = nil,
    help: String? = nil,
    value: Any? = nil,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
) {
    setRole(builder, element, kAXButtonRole as String)
    if let description { builder.setAttribute(element, kAXDescriptionAttribute as String, description) }
    if let title { builder.setAttribute(element, kAXTitleAttribute as String, title) }
    if let help { builder.setAttribute(element, kAXHelpAttribute as String, help) }
    if let value { builder.setAttribute(element, kAXValueAttribute as String, value) }
    setFrame(builder, element, x: x, y: y, width: width, height: height)
}

private func makeToolbar(
    _ builder: FakeAXRuntimeBuilder,
    baseID: Int,
    mixerDescription: String
) -> AXUIElement {
    let toolbar = builder.element(baseID)
    let leaveFolder = builder.element(baseID + 1)
    let segments = builder.element(baseID + 2)
    let staticText = builder.element(baseID + 6)
    let sendsOnFaders = builder.element(baseID + 7)
    let popup = builder.element(baseID + 8)
    let viewMode = builder.element(baseID + 9)
    let filter = builder.element(baseID + 13)
    let widthMode = builder.element(baseID + 22)

    setNamedContainer(
        builder,
        toolbar,
        role: kAXGroupRole as String,
        description: mixerDescription,
        x: 603,
        y: 405,
        width: 1317,
        height: 37
    )
    setButton(
        builder,
        leaveFolder,
        description: "Leave Folder",
        help: "Leave Folder",
        x: 612,
        y: 413,
        width: 35,
        height: 23
    )

    setRole(builder, segments, kAXGroupRole as String)
    setFrame(builder, segments, x: 653, y: 413, width: 213, height: 23)
    let segmentButtons = (0..<3).map { builder.element(baseID + 3 + $0) }
    for (button, title) in zip(segmentButtons, ["Edit", "Options", "View"]) {
        setButton(builder, button, title: title, x: 653, y: 413, width: 71, height: 23)
    }
    builder.setChildren(segments, segmentButtons)

    setRole(builder, staticText, kAXStaticTextRole as String)
    builder.setAttribute(staticText, kAXValueAttribute as String, "Sends on Faders:")
    setFrame(builder, staticText, x: 873, y: 413, width: 107, height: 25)

    setRole(builder, sendsOnFaders, kAXCheckBoxRole as String)
    builder.setAttribute(sendsOnFaders, kAXTitleAttribute as String, "Sends on Faders:")
    builder.setAttribute(
        sendsOnFaders,
        kAXHelpAttribute as String,
        "Sends on Faders - On/Off. Swaps the Pan knob and Fader on channel strips."
    )
    builder.setAttribute(sendsOnFaders, kAXValueAttribute as String, 0)
    setFrame(builder, sendsOnFaders, x: 981, y: 413, width: 32, height: 23)

    setRole(builder, popup, kAXPopUpButtonRole as String)
    builder.setAttribute(
        popup,
        kAXHelpAttribute as String,
        "Off, Sends on Faders pop-up menu. Assigns the Pan knob and Fader on channel strips."
    )
    builder.setAttribute(popup, kAXValueAttribute as String, "Off")
    setFrame(builder, popup, x: 1013, y: 413, width: 118, height: 23)

    setRole(builder, viewMode, kAXRadioGroupRole as String)
    setFrame(builder, viewMode, x: 1175, y: 413, width: 172, height: 23)
    let viewButtons = (0..<3).map { builder.element(baseID + 10 + $0) }
    for (button, title) in zip(viewButtons, ["Single", "Tracks", "All"]) {
        setButton(builder, button, title: title, x: 1175, y: 413, width: 57, height: 23)
    }
    builder.setChildren(viewMode, viewButtons)

    setRole(builder, filter, kAXGroupRole as String)
    setFrame(builder, filter, x: 1359, y: 412, width: 481, height: 23)
    let filterButtons = (0..<8).map { builder.element(baseID + 14 + $0) }
    for (offset, button) in filterButtons.enumerated() {
        setButton(builder, button, title: "Filter \(offset + 1)", x: 1359, y: 412, width: 60, height: 23)
    }
    builder.setChildren(filter, filterButtons)

    setRole(builder, widthMode, kAXRadioGroupRole as String)
    setFrame(builder, widthMode, x: 1845, y: 412, width: 67, height: 23)
    let widthButtons = (0..<2).map { builder.element(baseID + 23 + $0) }
    for (button, title) in zip(widthButtons, ["Narrow", "Wide"]) {
        setButton(builder, button, title: title, x: 1845, y: 412, width: 33, height: 23)
    }
    builder.setChildren(widthMode, widthButtons)

    builder.setChildren(toolbar, [
        leaveFolder,
        segments,
        staticText,
        sendsOnFaders,
        popup,
        viewMode,
        filter,
        widthMode,
    ])
    return toolbar
}

private func makeSimpleStrip(
    _ builder: FakeAXRuntimeBuilder,
    id: Int,
    name: String,
    x: CGFloat
) -> AXUIElement {
    let strip = builder.element(id)
    setRole(builder, strip, kAXLayoutItemRole as String)
    builder.setAttribute(strip, kAXDescriptionAttribute as String, name)
    setFrame(builder, strip, x: x, y: 442, width: 67, height: 623)
    return strip
}

private func make123MixerFixture(
    stripCount: Int,
    mixerDescription: String = "Mixer",
    includeStripsContainer: Bool = true,
    firstStrip: AXUIElement? = nil,
    builder: FakeAXRuntimeBuilder = FakeAXRuntimeBuilder()
) -> Mixer123Fixture {
    let app = builder.element(10)
    let window = builder.element(11)
    let outer = builder.element(12)
    let content = builder.element(13)
    let layoutArea = builder.element(14)
    let toolbar = makeToolbar(builder, baseID: 100, mixerDescription: mixerDescription)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    setRole(builder, window, kAXWindowRole as String)
    builder.setChildren(window, [outer])

    setNamedContainer(
        builder,
        outer,
        role: kAXGroupRole as String,
        description: mixerDescription,
        x: 603,
        y: 405,
        width: 1317,
        height: 675
    )
    setRole(builder, content, kAXGroupRole as String)
    setFrame(builder, content, x: 603, y: 442, width: 1317, height: 638)

    setNamedContainer(
        builder,
        layoutArea,
        role: axLayoutAreaRole,
        description: mixerDescription,
        x: 603,
        y: 442,
        width: 1317,
        height: 638
    )

    var strips: [AXUIElement] = []
    if includeStripsContainer {
        for i in 0..<stripCount {
            if i == 0, let firstStrip {
                strips.append(firstStrip)
            } else {
                strips.append(makeSimpleStrip(builder, id: 200 + i, name: "Track \(i + 1)", x: 695 + CGFloat(i * 67)))
            }
        }
        builder.setChildren(layoutArea, strips)
        builder.setChildren(content, [layoutArea])
        builder.setChildren(outer, [toolbar, content])
    } else {
        builder.setChildren(outer, [toolbar])
    }

    return Mixer123Fixture(
        runtime: builder.makeLogicRuntime(appElement: app),
        layoutArea: layoutArea,
        strips: strips
    )
}

private func make122MixerFixture(stripCount: Int = 3) -> Mixer123Fixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(20)
    let window = builder.element(21)
    let mixerGroup = builder.element(22)
    let layoutArea = builder.element(23)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    setRole(builder, window, kAXWindowRole as String)
    builder.setChildren(window, [mixerGroup])
    setNamedContainer(
        builder,
        mixerGroup,
        role: kAXGroupRole as String,
        description: "Mixer",
        x: 603,
        y: 405,
        width: 1317,
        height: 675
    )
    setNamedContainer(
        builder,
        layoutArea,
        role: axLayoutAreaRole,
        description: "Mixer",
        x: 603,
        y: 442,
        width: 1317,
        height: 638
    )
    let strips = (0..<stripCount).map { i in
        makeSimpleStrip(builder, id: 240 + i, name: "Track \(i + 1)", x: 695 + CGFloat(i * 67))
    }
    builder.setChildren(layoutArea, strips)
    builder.setChildren(mixerGroup, [layoutArea])

    return Mixer123Fixture(
        runtime: builder.makeLogicRuntime(appElement: app),
        layoutArea: layoutArea,
        strips: strips
    )
}

private func makeInspectorOnly123Runtime() -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(30)
    let window = builder.element(31)
    let inspector = builder.element(32)
    let inspectorWrapper = builder.element(33)
    let inspectorLayout = builder.element(34)
    let strips = [
        makeSimpleStrip(builder, id: 35, name: "Deluxe Classic", x: 366),
        makeSimpleStrip(builder, id: 36, name: "Stereo Out", x: 484),
    ]

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    setRole(builder, window, kAXWindowRole as String)
    builder.setChildren(window, [inspector])
    setNamedContainer(
        builder,
        inspector,
        role: kAXGroupRole as String,
        description: "Inspector",
        x: 0,
        y: 0,
        width: 603,
        height: 1080
    )
    setNamedContainer(
        builder,
        inspectorWrapper,
        role: kAXGroupRole as String,
        description: "Mixer",
        x: 366,
        y: 394,
        width: 235,
        height: 685
    )
    setNamedContainer(
        builder,
        inspectorLayout,
        role: axLayoutAreaRole,
        description: "Mixer",
        x: 366,
        y: 394,
        width: 235,
        height: 685
    )
    builder.setChildren(inspectorLayout, strips)
    builder.setChildren(inspectorWrapper, [inspectorLayout])
    builder.setChildren(inspector, [inspectorWrapper])

    return builder.makeLogicRuntime(appElement: app)
}

private func makeLiveDumpStrip(_ builder: FakeAXRuntimeBuilder, id: Int) -> AXUIElement {
    let strip = builder.element(id)
    let name = builder.element(id + 1)
    let mute = builder.element(id + 2)
    let solo = builder.element(id + 3)
    let fader = builder.element(id + 4)
    let faderKnob = builder.element(id + 5)
    let faderLevel = builder.element(id + 6)
    let peak = builder.element(id + 7)
    let pan = builder.element(id + 8)
    let panReadout = builder.element(id + 9)
    let automation = builder.element(id + 10)
    let automationCheck = builder.element(id + 11)
    let automationList = builder.element(id + 12)
    let group = builder.element(id + 13)
    let output = builder.element(id + 14)
    let send = builder.element(id + 15)
    let occupied = builder.element(id + 16)
    let bypass = builder.element(id + 17)
    let open = builder.element(id + 18)
    let list = builder.element(id + 19)
    let emptyAudioPlugin = builder.element(id + 20)
    let midiPlugin = builder.element(id + 21)
    let eq = builder.element(id + 22)
    let gainReduction = builder.element(id + 23)
    let setting = builder.element(id + 24)

    setRole(builder, strip, kAXLayoutItemRole as String)
    builder.setAttribute(strip, kAXDescriptionAttribute as String, "Deluxe Classic")
    setFrame(builder, strip, x: 695, y: 442, width: 67, height: 623)

    setRole(builder, name, kAXTextFieldRole as String)
    builder.setAttribute(name, kAXDescriptionAttribute as String, "name")
    builder.setAttribute(name, kAXHelpAttribute as String, "Name field. Double-click to rename the channel strip. ")
    builder.setAttribute(name, kAXValueAttribute as String, "Deluxe Classic")
    setFrame(builder, name, x: 695, y: 1029, width: 66, height: 24)

    setButton(builder, mute, description: "mute", help: "Mute button. Silence a channel strip so it’s no longer audible.", value: "off", x: 699, y: 1006, width: 28, height: 18)
    builder.setAttribute(mute, kAXSubroleAttribute as String, kAXSwitchSubrole as String)
    setButton(builder, solo, description: "solo", help: "Solo button. Isolate a channel strip’s signal so that it can be heard.", value: "off", x: 729, y: 1006, width: 28, height: 18)
    builder.setAttribute(solo, kAXSubroleAttribute as String, kAXSwitchSubrole as String)

    setRole(builder, fader, kAXSliderRole as String)
    builder.setAttribute(fader, kAXDescriptionAttribute as String, "volume fader")
    builder.setAttribute(fader, kAXHelpAttribute as String, "Volume fader. Set a track’s playback volume.")
    builder.setAttribute(fader, kAXValueAttribute as String, 173)
    setFrame(builder, fader, x: 702, y: 824, width: 20, height: 180)
    setRole(builder, faderKnob, kAXValueIndicatorRole as String)
    builder.setAttribute(faderKnob, kAXDescriptionAttribute as String, "fader knob")
    setFrame(builder, faderKnob, x: 701, y: 858, width: 22, height: 46)
    builder.setChildren(fader, [faderKnob])

    setRole(builder, faderLevel, kAXTextFieldRole as String)
    builder.setAttribute(faderLevel, kAXDescriptionAttribute as String, "volume fader level")
    builder.setAttribute(faderLevel, kAXTitleAttribute as String, "volume fader level, 0.0 dB")
    setFrame(builder, faderLevel, x: 700, y: 805, width: 27, height: 18)

    setButton(builder, peak, description: "peak level meter", title: "peak level meter", help: "Peak Level display. Shows the signal peak during playback.", value: "signal clipping off", x: 729, y: 805, width: 27, height: 18)

    setRole(builder, pan, kAXSliderRole as String)
    builder.setAttribute(pan, kAXDescriptionAttribute as String, "pan")
    builder.setAttribute(pan, kAXHelpAttribute as String, "Pan/Balance knob. Drag vertically to position the channel strip signal.")
    builder.setAttribute(pan, kAXValueAttribute as String, 0)
    setFrame(builder, pan, x: 710, y: 763, width: 37, height: 37)
    setRole(builder, panReadout, kAXStaticTextRole as String)
    builder.setAttribute(panReadout, kAXDescriptionAttribute as String, "knob readout")
    setFrame(builder, panReadout, x: 710, y: 763, width: 37, height: 37)
    builder.setChildren(pan, [panReadout])

    setNamedContainer(builder, automation, role: kAXGroupRole as String, description: "Read, automation enabled", x: 699, y: 701, width: 58, height: 18)
    setRole(builder, automationCheck, kAXCheckBoxRole as String)
    builder.setAttribute(automationCheck, kAXDescriptionAttribute as String, "automation")
    builder.setAttribute(automationCheck, kAXValueAttribute as String, 1)
    setFrame(builder, automationCheck, x: 699, y: 701, width: 20, height: 18)
    setButton(builder, automationList, description: "list", x: 719, y: 701, width: 38, height: 18)
    builder.setChildren(automation, [automationCheck, automationList])

    setRole(builder, group, kAXPopUpButtonRole as String)
    builder.setAttribute(group, kAXDescriptionAttribute as String, "group")
    builder.setAttribute(group, kAXTitleAttribute as String, "group")
    builder.setAttribute(group, kAXHelpAttribute as String, "Group slot. Add the channel strip to a group.")
    setFrame(builder, group, x: 700, y: 678, width: 56, height: 18)

    setButton(builder, output, description: "Stereo Output", help: "Output slot. Click and hold to choose the channel strip output destination.", x: 699, y: 655, width: 58, height: 18)
    setButton(builder, send, description: "send button", help: "Send slot. Route the signal to an aux channel strip.", x: 699, y: 629, width: 40, height: 18)

    setNamedContainer(builder, occupied, role: kAXGroupRole as String, description: "Gain", x: 699, y: 559, width: 58, height: 18)
    setRole(builder, bypass, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
    builder.setAttribute(bypass, kAXValueAttribute as String, 0)
    setFrame(builder, bypass, x: 699, y: 559, width: 20, height: 18)
    setButton(builder, open, description: "open", x: 719, y: 559, width: 21, height: 18)
    setButton(builder, list, description: "list", x: 740, y: 559, width: 17, height: 18)
    builder.setChildren(occupied, [bypass, open, list])

    setButton(
        builder,
        emptyAudioPlugin,
        description: "audio plug-in",
        help: "Audio Effect slot. Insert an audio effect. Click an occupied slot to open the plug-in.",
        x: 699,
        y: 585,
        width: 58,
        height: 18
    )
    setButton(builder, midiPlugin, description: "MIDI plug-in", help: "MIDI Effect slot. Insert a MIDI effect. Click an occupied slot to open the plug-in.", x: 699, y: 533, width: 58, height: 18)
    setButton(builder, eq, description: "EQ", help: "EQ display. Click to add a Channel EQ or open an inserted Channel or Linear Phase EQ.", value: "off", x: 699, y: 499, width: 58, height: 29)
    setButton(builder, gainReduction, description: "gain reduction meter", help: "Gain reduction meter. Shows the gain reduction of the first Compressor.", value: "off", x: 699, y: 486, width: 58, height: 9)
    builder.setAttribute(gainReduction, kAXSubroleAttribute as String, kAXSwitchSubrole as String)
    setButton(builder, setting, description: "Deluxe Classic", help: "Setting button. Load and save channel strip settings, which contain settings for all plug-ins.", x: 699, y: 464, width: 58, height: 18)

    builder.setChildren(strip, [
        name,
        mute,
        solo,
        fader,
        faderLevel,
        peak,
        pan,
        automation,
        group,
        output,
        send,
        emptyAudioPlugin,
        occupied,
        midiPlugin,
        eq,
        gainReduction,
        setting,
    ])
    return strip
}

@Suite("Mixer123SelectionTests")
struct Mixer123SelectionTests {
    @Test
    func test123MixerSelectsStripsContainerNotToolbar() {
        let fixture = make123MixerFixture(stripCount: 3)

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea))
    }

    @Test(arguments: [1, 3, 8, 9, 12])
    func test123MixerSelectionIndependentOfStripCount(_ stripCount: Int) {
        let fixture = make123MixerFixture(stripCount: stripCount)

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea), "strip count \(stripCount)")
    }

    @Test
    func test123ToolbarAloneYieldsNoMixer() {
        let fixture = make123MixerFixture(stripCount: 0, includeStripsContainer: false)

        #expect(AXLogicProElements.getMixerArea(runtime: fixture.runtime) == nil)
    }

    @Test
    func test122ShapeStillSelected() {
        let fixture = make122MixerFixture()

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea))
    }

    @Test
    func test123KoreanLocaleSelection() {
        let fixture = make123MixerFixture(stripCount: 3, mixerDescription: "믹서")

        let mixer = AXLogicProElements.getMixerArea(runtime: fixture.runtime)

        #expect(mixer != nil)
        #expect(CFEqual(mixer!, fixture.layoutArea))
    }

    @Test
    func test123InspectorAreaStillExcluded() {
        let runtime = makeInspectorOnly123Runtime()

        #expect(AXLogicProElements.getMixerArea(runtime: runtime) == nil)
    }

    @Test
    func test123EnumerationEndToEnd() throws {
        let builder = FakeAXRuntimeBuilder()
        let strip = makeLiveDumpStrip(builder, id: 500)
        let fixture = make123MixerFixture(stripCount: 3, firstStrip: strip, builder: builder)

        let mixer = try #require(AXLogicProElements.getMixerArea(runtime: fixture.runtime))
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: fixture.runtime.ax)
        #expect(strips.count == 3)
        let firstStrip = try #require(strips.first)
        #expect(CFEqual(firstStrip, strip))

        let slots = AXLogicProElements.audioPluginInsertSlots(in: firstStrip, runtime: fixture.runtime.ax)

        #expect(slots.count == 2)
        #expect(slots.map(\.index) == [0, 1])
        let firstSlot = try #require(slots.first)
        let secondSlot = try #require(slots.dropFirst().first)
        #expect(firstSlot.readStatus == .empty)
        #expect(firstSlot.name == nil)
        #expect(secondSlot.readStatus == .occupiedReadable)
        #expect(secondSlot.name == "Gain")
        let bypassed = secondSlot.isBypassed!
        #expect(!bypassed)
    }
}
