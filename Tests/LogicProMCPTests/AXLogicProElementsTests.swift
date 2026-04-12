@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

@Test func testAXLogicProElementsFindTransportTrackMixerAndArrangementAreas() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let window = builder.element(2)
    let toolbar = builder.element(3)
    let trackList = builder.element(4)
    let mixer = builder.element(5)
    let arrangement = builder.element(6)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [toolbar, trackList, mixer, arrangement])

    builder.setAttribute(toolbar, kAXRoleAttribute as String, kAXToolbarRole as String)
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
    builder.setAttribute(arrangement, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(arrangement, kAXIdentifierAttribute as String, "Arrangement")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.appRoot(runtime: runtime) == app)
    #expect(AXLogicProElements.mainWindow(runtime: runtime) == window)
    #expect(AXLogicProElements.getTransportBar(runtime: runtime) == toolbar)
    #expect(AXLogicProElements.getTrackHeaders(runtime: runtime) == trackList)
    #expect(AXLogicProElements.getMixerArea(runtime: runtime) == mixer)
    #expect(AXLogicProElements.getArrangementArea(runtime: runtime) == arrangement)
}

@Test func testAXLogicProElementsResolveButtonsSlidersAndTrackFields() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let window = builder.element(2)
    let transportGroup = builder.element(3)
    let playButton = builder.element(4)
    let recordButton = builder.element(5)
    let trackList = builder.element(6)
    let trackHeader = builder.element(7)
    let muteButton = builder.element(8)
    let soloButton = builder.element(9)
    let armButton = builder.element(10)
    let nameField = builder.element(11)
    let mixer = builder.element(12)
    let strip = builder.element(13)
    let fader = builder.element(14)
    let pan = builder.element(15)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [transportGroup, trackList, mixer])

    builder.setAttribute(transportGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transportGroup, kAXIdentifierAttribute as String, "Transport")
    builder.setChildren(transportGroup, [playButton, recordButton])
    builder.setAttribute(playButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(playButton, kAXTitleAttribute as String, "Play")
    builder.setAttribute(recordButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(recordButton, kAXDescriptionAttribute as String, "Record")

    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [trackHeader])
    builder.setChildren(trackHeader, [muteButton, soloButton, armButton, nameField])
    builder.setAttribute(muteButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(muteButton, kAXDescriptionAttribute as String, "Mute Track 1")
    builder.setAttribute(soloButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(soloButton, kAXDescriptionAttribute as String, "Solo Track 1")
    builder.setAttribute(armButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(armButton, kAXDescriptionAttribute as String, "Record Track 1")
    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(nameField, kAXValueAttribute as String, "Lead Vox")

    builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setChildren(strip, [fader, pan])
    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.findTransportButton(named: "Play", runtime: runtime) == playButton)
    #expect(AXLogicProElements.findTransportButton(named: "Record", runtime: runtime) == recordButton)
    #expect(AXLogicProElements.findTrackHeader(at: 0, runtime: runtime) == trackHeader)
    #expect(AXLogicProElements.allTrackHeaders(runtime: runtime) == [trackHeader])
    #expect(AXLogicProElements.findTrackMuteButton(trackIndex: 0, runtime: runtime) == muteButton)
    #expect(AXLogicProElements.findTrackSoloButton(trackIndex: 0, runtime: runtime) == soloButton)
    #expect(AXLogicProElements.findTrackArmButton(trackIndex: 0, runtime: runtime) == armButton)
    #expect(AXLogicProElements.findTrackNameField(trackIndex: 0, runtime: runtime) == nameField)
    #expect(AXLogicProElements.findFader(trackIndex: 0, runtime: runtime) == fader)
    #expect(AXLogicProElements.findPanKnob(trackIndex: 0, runtime: runtime) == pan)
}

@Test func testAXLogicProElementsResolveMenuItemsAcrossNestedMenus() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let menuBar = builder.element(2)
    let fileMenu = builder.element(3)
    let newItem = builder.element(4)

    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(menuBar, [fileMenu])
    builder.setAttribute(fileMenu, kAXTitleAttribute as String, "File")
    builder.setChildren(fileMenu, [newItem])
    builder.setAttribute(newItem, kAXTitleAttribute as String, "New...")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getMenuBar(runtime: runtime) == menuBar)
    #expect(AXLogicProElements.menuItem(path: ["File", "New..."], runtime: runtime) == newItem)
    #expect(AXLogicProElements.menuItem(path: ["Edit", "Undo"], runtime: runtime) == nil)
}

@Test func testAXLogicProElementsFallbacksResolveScrollAreasAndOutline() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(21)
    let window = builder.element(22)
    let transportGroup = builder.element(23)
    let tracksScroll = builder.element(24)
    let mixerScroll = builder.element(25)
    let arrangementScroll = builder.element(26)
    let trackHeader = builder.element(27)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [transportGroup, tracksScroll, mixerScroll, arrangementScroll])

    builder.setAttribute(transportGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transportGroup, kAXIdentifierAttribute as String, "Transport")

    builder.setAttribute(tracksScroll, kAXRoleAttribute as String, kAXScrollAreaRole as String)
    builder.setAttribute(tracksScroll, kAXIdentifierAttribute as String, "Tracks")
    builder.setChildren(tracksScroll, [trackHeader])

    builder.setAttribute(mixerScroll, kAXRoleAttribute as String, kAXScrollAreaRole as String)
    builder.setAttribute(mixerScroll, kAXIdentifierAttribute as String, "Mixer")

    builder.setAttribute(arrangementScroll, kAXRoleAttribute as String, kAXScrollAreaRole as String)
    builder.setAttribute(arrangementScroll, kAXIdentifierAttribute as String, "Arrangement")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getTransportBar(runtime: runtime) == transportGroup)
    #expect(AXLogicProElements.getTrackHeaders(runtime: runtime) == tracksScroll)
    #expect(AXLogicProElements.getMixerArea(runtime: runtime) == mixerScroll)
    #expect(AXLogicProElements.getArrangementArea(runtime: runtime) == arrangementScroll)
    #expect(AXLogicProElements.findTrackHeader(at: -1, runtime: runtime) == nil)
    #expect(AXLogicProElements.findTrackHeader(at: 1, runtime: runtime) == nil)
    #expect(AXLogicProElements.findTransportButton(named: "Stop", runtime: runtime) == nil)
}

@Test func testAXLogicProElementsDoesNotTreatPlainWindowAsTransportWithoutTransportSignature() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(40)
    let window = builder.element(41)
    let genericGroup = builder.element(42)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [genericGroup])
    builder.setAttribute(genericGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(genericGroup, kAXIdentifierAttribute as String, "Inspector")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getTransportBar(runtime: runtime) == nil)
}

@Test func testAXLogicProElementsOutlineAndTextFieldFallbacks() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(31)
    let window = builder.element(32)
    let outline = builder.element(33)
    let header = builder.element(34)
    let nameField = builder.element(35)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [outline])
    builder.setAttribute(outline, kAXRoleAttribute as String, kAXOutlineRole as String)
    builder.setChildren(outline, [header])
    builder.setChildren(header, [nameField])
    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    builder.setAttribute(nameField, kAXValueAttribute as String, "Keys")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getTrackHeaders(runtime: runtime) == outline)
    #expect(AXLogicProElements.findTrackNameField(trackIndex: 0, runtime: runtime) == nameField)
    #expect(AXLogicProElements.findFader(trackIndex: 0, runtime: runtime) == nil)
    #expect(AXLogicProElements.findPanKnob(trackIndex: 0, runtime: runtime) == nil)
}
