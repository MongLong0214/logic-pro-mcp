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
    // v3.1.8 (Issue #7) — strict allTrackHeaders requires AXLayoutItem role.
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
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

@Test func testAXLogicProElementsFindTrackNameFieldPrefersTextFieldOverStaticText() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(90)
    let window = builder.element(91)
    let trackList = builder.element(92)
    let header = builder.element(93)
    let staticName = builder.element(94)
    let editableName = builder.element(95)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [header])
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(header, [staticName, editableName])
    builder.setAttribute(staticName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(staticName, kAXValueAttribute as String, "Old Label")
    builder.setAttribute(editableName, kAXRoleAttribute as String, kAXTextFieldRole as String)
    builder.setAttribute(editableName, kAXDescriptionAttribute as String, "Live Name")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.findTrackNameField(trackIndex: 0, runtime: runtime) == editableName)
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
    // v3.1.8 (Issue #7) — strict allTrackHeaders contract.
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)

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

@Test func testAXLogicProElementsFallsBackToLegacyMainWindowWhenOnlyDialogsAreEnumerable() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(310)
    let legacyMain = builder.element(311)
    let dialog = builder.element(312)
    let systemDialog = builder.element(313)

    builder.setAttribute(app, kAXMainWindowAttribute as String, legacyMain)
    builder.setAttribute(app, kAXWindowsAttribute as String, [dialog, systemDialog])
    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(systemDialog, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.mainWindow(runtime: runtime) == legacyMain)
    #expect(AXLogicProElements.dialogPresent(runtime: runtime))
}

@Test func testAXLogicProElementsControlBarCheckboxesAndLocatorSliders() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(320)
    let window = builder.element(321)
    let controlBar = builder.element(322)
    let recordTitle = builder.element(323)
    let cycleDescription = builder.element(324)
    let barSlider = builder.element(325)
    let beatSlider = builder.element(326)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [recordTitle, cycleDescription, barSlider, beatSlider])

    builder.setAttribute(recordTitle, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(recordTitle, kAXTitleAttribute as String, "Record")
    builder.setAttribute(recordTitle, kAXValueAttribute as String, NSNumber(value: true))
    builder.setAttribute(cycleDescription, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(cycleDescription, kAXDescriptionAttribute as String, "사이클")
    builder.setAttribute(cycleDescription, kAXValueAttribute as String, false)
    builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
    builder.setAttribute(beatSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(beatSlider, kAXDescriptionAttribute as String, "비트")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getControlBar(runtime: runtime) == controlBar)
    #expect(AXLogicProElements.findControlBarCheckbox(
        named: "녹음",
        englishName: "Record",
        runtime: runtime
    ) == recordTitle)
    #expect(AXLogicProElements.findControlBarCheckbox(
        named: "사이클",
        englishName: "Cycle",
        runtime: runtime
    ) == cycleDescription)
    #expect(AXLogicProElements.readControlBarCheckboxValue(
        named: "녹음",
        englishName: "Record",
        runtime: runtime
    )!)
    #expect(!(AXLogicProElements.readControlBarCheckboxValue(
        named: "사이클",
        englishName: "Cycle",
        runtime: runtime
    )!))
    #expect(AXLogicProElements.findControlBarBarSlider(runtime: runtime) == barSlider)
    #expect(AXLogicProElements.findControlBarBeatSlider(runtime: runtime) == beatSlider)
}

@Test func testAXLogicProElementsFindsLogic12MixerLayoutAreaAndSkipsInspectorMixer() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(160)
    let window = builder.element(161)
    let inspector = builder.element(162)
    let inspectorMixer = builder.element(163)
    let inspectorStrip = builder.element(164)
    let mixerGroup = builder.element(165)
    let mixerToolbar = builder.element(166)
    let mixerLayout = builder.element(167)

    let strips = (0..<3).map { i in builder.element(170 + i) }
    let faders = (0..<3).map { i in builder.element(180 + i) }
    let pans = (0..<3).map { i in builder.element(190 + i) }

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [inspector, mixerGroup])

    builder.setAttribute(inspector, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(inspector, kAXDescriptionAttribute as String, "인스펙터")
    builder.setChildren(inspector, [inspectorMixer])
    builder.setAttribute(inspectorMixer, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(inspectorMixer, kAXDescriptionAttribute as String, "믹서")
    builder.setChildren(inspectorMixer, [inspectorStrip])
    builder.setAttribute(inspectorStrip, kAXRoleAttribute as String, kAXLayoutItemRole as String)

    builder.setAttribute(mixerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(mixerGroup, kAXDescriptionAttribute as String, "믹서")
    builder.setChildren(mixerGroup, [mixerToolbar, mixerLayout])
    builder.setAttribute(mixerToolbar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(mixerToolbar, kAXDescriptionAttribute as String, "믹서")
    builder.setAttribute(mixerLayout, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(mixerLayout, kAXDescriptionAttribute as String, "믹서")
    builder.setChildren(mixerLayout, strips)

    for i in strips.indices {
        builder.setAttribute(strips[i], kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(strips[i], kAXDescriptionAttribute as String, "Track \(i + 1)")
        builder.setChildren(strips[i], [faders[i], pans[i]])
        builder.setAttribute(faders[i], kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(faders[i], kAXDescriptionAttribute as String, "볼륨 페이더")
        builder.setAttribute(pans[i], kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(pans[i], kAXDescriptionAttribute as String, "패닝")
    }

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getMixerArea(runtime: runtime) == mixerLayout)
}

@Test func testAXLogicProElementsDoesNotTreatInspectorChannelStripsAsMixerArea() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(210)
    let window = builder.element(211)
    let inspector = builder.element(212)
    let inspectorMixer = builder.element(213)
    let inspectorStrip = builder.element(214)
    let fader = builder.element(215)
    let pan = builder.element(216)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [inspector])
    builder.setAttribute(inspector, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(inspector, kAXDescriptionAttribute as String, "Inspector")
    builder.setChildren(inspector, [inspectorMixer])
    builder.setAttribute(inspectorMixer, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(inspectorMixer, kAXDescriptionAttribute as String, "Mixer")
    builder.setChildren(inspectorMixer, [inspectorStrip])
    builder.setAttribute(inspectorStrip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(inspectorStrip, [fader, pan])
    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(fader, kAXDescriptionAttribute as String, "Volume Fader")
    builder.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(pan, kAXDescriptionAttribute as String, "Pan")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getMixerArea(runtime: runtime) == nil)
}

@Test func testAXLogicProElementsFindsFaderAndPanByLocalizedDescription() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(230)
    let window = builder.element(231)
    let mixerLayout = builder.element(232)
    let strip = builder.element(233)
    let send = builder.element(234)
    let pan = builder.element(235)
    let fader = builder.element(236)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [mixerLayout])
    builder.setAttribute(mixerLayout, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(mixerLayout, kAXDescriptionAttribute as String, "믹서")
    builder.setChildren(mixerLayout, [strip])
    builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(strip, kAXDescriptionAttribute as String, "Roland TR-909")
    builder.setChildren(strip, [send, pan, fader])
    builder.setAttribute(send, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(send, kAXDescriptionAttribute as String, "센드 노브")
    builder.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(pan, kAXHelpAttribute as String, "패닝 노브 및 밸런스 노브")
    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(fader, kAXDescriptionAttribute as String, "볼륨 페이더")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.findFader(trackIndex: 0, runtime: runtime) == fader)
    #expect(AXLogicProElements.findPanKnob(trackIndex: 0, runtime: runtime) == pan)
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
    // v3.1.8 (Issue #7) — outline fallback only matches when children
    // contain AXLayoutItem (anti Inspector-contamination).
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(header, [nameField])
    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    builder.setAttribute(nameField, kAXValueAttribute as String, "Keys")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getTrackHeaders(runtime: runtime) == outline)
    #expect(AXLogicProElements.findTrackNameField(trackIndex: 0, runtime: runtime) == nameField)
    #expect(AXLogicProElements.findFader(trackIndex: 0, runtime: runtime) == nil)
    #expect(AXLogicProElements.findPanKnob(trackIndex: 0, runtime: runtime) == nil)
}

@Test func testGetTrackHeadersAcceptsLogic122TracksHeaderDescription() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(640)
    let window = builder.element(641)
    let scrollArea = builder.element(642)
    let headerGroup = builder.element(643)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [scrollArea])
    builder.setAttribute(scrollArea, kAXRoleAttribute as String, kAXScrollAreaRole as String)
    builder.setChildren(scrollArea, [headerGroup])
    builder.setAttribute(headerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerGroup, kAXDescriptionAttribute as String, "Tracks header")

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getTrackHeaders(runtime: runtime) == headerGroup)
}

@Test func testGetTrackHeadersUsesLanguageNeutralSelectionStructure() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(660)
    let window = builder.element(661)
    let scrollArea = builder.element(662)
    let headerGroup = builder.element(663)
    let trackHeader = builder.element(664)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [scrollArea])
    builder.setAttribute(scrollArea, kAXRoleAttribute as String, kAXScrollAreaRole as String)
    builder.setChildren(scrollArea, [headerGroup])
    builder.setAttribute(headerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerGroup, kAXDescriptionAttribute as String, "Localized track rail")
    builder.setChildren(headerGroup, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(headerGroup, kAXSelectedChildrenAttribute as String, [trackHeader])

    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.getTrackHeaders(runtime: runtime) == headerGroup)
}

@Test func testGetTrackHeadersAcceptsTrackHeaderDescriptionVariants() {
    for desc in ["Track Headers", "Track Header", "Tracks Headers", "Tracks header", "트랙 헤더"] {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(650)
        let window = builder.element(651)
        let scrollArea = builder.element(652)
        let headerGroup = builder.element(653)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [scrollArea])
        builder.setAttribute(scrollArea, kAXRoleAttribute as String, kAXScrollAreaRole as String)
        builder.setChildren(scrollArea, [headerGroup])
        builder.setAttribute(headerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(headerGroup, kAXDescriptionAttribute as String, desc)

        let runtime = builder.makeLogicRuntime(appElement: app)
        #expect(
            AXLogicProElements.getTrackHeaders(runtime: runtime) == headerGroup,
            "Strategy 3 should match desc=\"\(desc)\""
        )
    }
}
