@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

@Test func testAXValueExtractorsReadScalarValuesAndRanges() {
    let builder = FakeAXRuntimeBuilder()
    let slider = builder.element(1)
    let text = builder.element(2)
    let selected = builder.element(4)
    let stringButton = builder.element(5)

    builder.setAttribute(slider, kAXValueAttribute as String, 0.75)
    builder.setAttribute(slider, kAXMinValueAttribute as String, -1.0)
    builder.setAttribute(slider, kAXMaxValueAttribute as String, 1.0)
    builder.setAttribute(text, kAXValueAttribute as String, "128.5 BPM")
    builder.setAttribute(selected, kAXSelectedAttribute as String, true)
    builder.setAttribute(stringButton, kAXValueAttribute as String, "true")

    let runtime = builder.makeAXRuntime()

    #expect(AXValueExtractors.extractSliderValue(slider, runtime: runtime) == 0.75)
    #expect(AXValueExtractors.extractTextValue(text, runtime: runtime) == "128.5 BPM")
    #expect(AXValueExtractors.extractButtonState(stringButton, runtime: runtime)!)
    #expect(AXValueExtractors.extractSelectedState(selected, runtime: runtime)!)
    #expect(AXValueExtractors.extractSliderRange(slider, runtime: runtime)?.min == -1.0)
    #expect(AXValueExtractors.extractSliderRange(slider, runtime: runtime)?.max == 1.0)
}

@Test func testAXValueExtractorsNormalizeLogicMixerVolumeAndPanRanges() {
    let builder = FakeAXRuntimeBuilder()
    let volume = builder.element(101)
    let panCenter = builder.element(102)
    let panLeft = builder.element(103)
    let panRight = builder.element(104)

    // Logic Pro 12.2 live AX dump shape:
    // volume fader AXValue=70, AXMin=0, AXMax=233
    // pan knob AXValue=0, AXMin=-64, AXMax=63
    builder.setAttribute(volume, kAXValueAttribute as String, 70)
    builder.setAttribute(volume, kAXMinValueAttribute as String, 0)
    builder.setAttribute(volume, kAXMaxValueAttribute as String, 233)
    builder.setAttribute(panCenter, kAXValueAttribute as String, 0)
    builder.setAttribute(panCenter, kAXMinValueAttribute as String, -64)
    builder.setAttribute(panCenter, kAXMaxValueAttribute as String, 63)
    builder.setAttribute(panLeft, kAXValueAttribute as String, -64)
    builder.setAttribute(panLeft, kAXMinValueAttribute as String, -64)
    builder.setAttribute(panLeft, kAXMaxValueAttribute as String, 63)
    builder.setAttribute(panRight, kAXValueAttribute as String, 63)
    builder.setAttribute(panRight, kAXMinValueAttribute as String, -64)
    builder.setAttribute(panRight, kAXMaxValueAttribute as String, 63)

    let runtime = builder.makeAXRuntime()

    #expect(AXValueExtractors.extractNormalizedSliderValue(volume, runtime: runtime) == 70.0 / 233.0)
    #expect(abs((AXValueExtractors.extractLogicMixerFaderValue(volume, runtime: runtime) ?? 0.0) - 0.4) < 0.002)
    #expect(abs(AXValueExtractors.logicMixerFaderPositionToContract(0.4206008583690987) - 0.5) < 0.002)
    #expect(abs(AXValueExtractors.logicMixerFaderPositionToContract(0.8111587982832618) - 0.8) < 0.002)
    #expect(AXValueExtractors.extractCenteredSliderValue(panCenter, runtime: runtime) == 0.0)
    #expect(AXValueExtractors.extractCenteredSliderValue(panLeft, runtime: runtime) == -1.0)
    #expect(AXValueExtractors.extractCenteredSliderValue(panRight, runtime: runtime) == 1.0)
}

@Test func testAXValueExtractorsDoNotApplyLogicFaderTaperWithoutLogicRawRange() {
    let builder = FakeAXRuntimeBuilder()
    let normalizedVolume = builder.element(201)
    let rangedVolume = builder.element(202)

    builder.setAttribute(normalizedVolume, kAXValueAttribute as String, 0.8)
    builder.setAttribute(rangedVolume, kAXValueAttribute as String, 0.8)
    builder.setAttribute(rangedVolume, kAXMinValueAttribute as String, 0.0)
    builder.setAttribute(rangedVolume, kAXMaxValueAttribute as String, 1.0)

    let runtime = builder.makeAXRuntime()

    #expect(AXValueExtractors.extractLogicMixerFaderValue(normalizedVolume, runtime: runtime) == 0.8)
    #expect(AXValueExtractors.extractLogicMixerFaderValue(rangedVolume, runtime: runtime) == 0.8)
}

@Test func testAXValueExtractorsBuildTrackStateFromHeader() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let name = builder.element(2)
    let mute = builder.element(3)
    let solo = builder.element(4)
    let arm = builder.element(5)

    builder.setChildren(header, [name, mute, solo, arm])
    builder.setAttribute(header, kAXDescriptionAttribute as String, "Audio color blue")
    builder.setAttribute(header, kAXTitleAttribute as String, "Audio Track")
    builder.setAttribute(header, kAXSelectedAttribute as String, true)

    builder.setAttribute(name, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(name, kAXValueAttribute as String, "Lead Vox")

    builder.setAttribute(mute, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(mute, kAXDescriptionAttribute as String, "Mute Track 1")
    builder.setAttribute(mute, kAXValueAttribute as String, 1)

    builder.setAttribute(solo, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(solo, kAXDescriptionAttribute as String, "Solo Track 1")
    builder.setAttribute(solo, kAXValueAttribute as String, 0)

    builder.setAttribute(arm, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(arm, kAXDescriptionAttribute as String, "Record Track 1")
    builder.setAttribute(arm, kAXValueAttribute as String, 1)

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 3, runtime: runtime)

    #expect(track.id == 3)
    #expect(track.name == "Lead Vox")
    #expect(track.type == .audio)
    #expect(track.isMuted)
    #expect(!track.isSoloed)
    #expect(track.isArmed)
    #expect(track.isSelected)
    #expect(track.color == "Audio color blue")
}

@Test func testAXValueExtractorsBuildTransportStateFromButtonsAndTexts() {
    let builder = FakeAXRuntimeBuilder()
    let transport = builder.element(1)
    let play = builder.element(2)
    let record = builder.element(3)
    let cycle = builder.element(4)
    let metronome = builder.element(5)
    let tempo = builder.element(6)
    let bars = builder.element(7)
    let time = builder.element(8)

    builder.setChildren(transport, [play, record, cycle, metronome, tempo, bars, time])

    builder.setAttribute(play, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(play, kAXDescriptionAttribute as String, "Play")
    builder.setAttribute(play, kAXValueAttribute as String, 1)

    builder.setAttribute(record, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(record, kAXDescriptionAttribute as String, "Record")
    builder.setAttribute(record, kAXValueAttribute as String, 1)

    builder.setAttribute(cycle, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cycle, kAXDescriptionAttribute as String, "Cycle")
    builder.setAttribute(cycle, kAXValueAttribute as String, 1)

    builder.setAttribute(metronome, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(metronome, kAXDescriptionAttribute as String, "Metronome")
    builder.setAttribute(metronome, kAXValueAttribute as String, 0)

    builder.setAttribute(tempo, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(tempo, kAXDescriptionAttribute as String, "Tempo")
    builder.setAttribute(tempo, kAXValueAttribute as String, "128.5 BPM")

    builder.setAttribute(bars, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(bars, kAXDescriptionAttribute as String, "Position")
    builder.setAttribute(bars, kAXValueAttribute as String, "9.1.1.1")

    builder.setAttribute(time, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(time, kAXDescriptionAttribute as String, "Time")
    builder.setAttribute(time, kAXValueAttribute as String, "00:01:02.003")

    let runtime = builder.makeAXRuntime()
    let state = AXValueExtractors.extractTransportState(from: transport, runtime: runtime)

    #expect(state.isPlaying)
    #expect(state.isRecording)
    #expect(state.isCycleEnabled)
    #expect(!state.isMetronomeEnabled)
    #expect(state.tempo == 128.5)
    #expect(state.position == "9.1.1.1")
    #expect(state.timePosition == "00:01:02.003")
    #expect(state.lastUpdated.timeIntervalSince1970 > 0)
}

@Test func testAXValueExtractorsFallbacksHandleStringsTitlesAndMissingStates() {
    let builder = FakeAXRuntimeBuilder()
    let sliderString = builder.element(10)
    let sliderInvalid = builder.element(11)
    let titledText = builder.element(12)
    let zeroButton = builder.element(13)
    let selectedMissing = builder.element(15)

    builder.setAttribute(sliderString, kAXValueAttribute as String, "0.25")
    builder.setAttribute(sliderInvalid, kAXValueAttribute as String, "not-a-double")
    builder.setAttribute(titledText, kAXTitleAttribute as String, "Fallback Title")
    builder.setAttribute(zeroButton, kAXValueAttribute as String, "0")

    let runtime = builder.makeAXRuntime()

    #expect(AXValueExtractors.extractSliderValue(sliderString, runtime: runtime) == 0.25)
    #expect(AXValueExtractors.extractSliderValue(sliderInvalid, runtime: runtime) == nil)
    #expect(AXValueExtractors.extractTextValue(titledText, runtime: runtime) == "Fallback Title")
    #expect(!(AXValueExtractors.extractButtonState(zeroButton, runtime: runtime)!))
    #expect(AXValueExtractors.extractSelectedState(selectedMissing, runtime: runtime) == nil)
    #expect(AXValueExtractors.extractSliderRange(sliderInvalid, runtime: runtime) == nil)
}

@Test func testAXValueExtractorsTrackFallbacksAndTypeInferenceVariants() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(20)
    let nameField = builder.element(21)
    let mute = builder.element(22)
    let unknownHeader = builder.element(23)

    builder.setChildren(header, [nameField, mute])
    builder.setAttribute(header, kAXDescriptionAttribute as String, "External MIDI color green")
    builder.setAttribute(header, kAXTitleAttribute as String, "External MIDI")

    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    builder.setAttribute(nameField, kAXValueAttribute as String, "808 Rack")

    builder.setAttribute(mute, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(mute, kAXDescriptionAttribute as String, "mute channel strip")
    builder.setAttribute(mute, kAXValueAttribute as String, "1")

    builder.setAttribute(unknownHeader, kAXTitleAttribute as String, "Mystery Track")

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 7, runtime: runtime)
    let unknownTrack = AXValueExtractors.extractTrackState(from: unknownHeader, index: 8, runtime: runtime)

    #expect(track.name == "808 Rack")
    #expect(track.type == .externalMIDI)
    #expect(track.isMuted)
    #expect(track.color == "External MIDI color green")
    #expect(unknownTrack.name == "Mystery Track")
    #expect(unknownTrack.type == .unknown)
    #expect(unknownTrack.color == nil)
}

@Test func testAXValueExtractorsClassifiesGMDeviceStripAsExternalMIDI() {
    // #131 — Logic's multichannel SMF open creates "GM Device N" strips. The
    // live header can carry an "audio"-shaped signal, so the gm-device check
    // MUST win over `.audio`. Misclassifying these as `.audio` hides the
    // silent-bounce risk (#128) before bounce.
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(900)
    let name = builder.element(901)
    let icon = builder.element(902)

    builder.setChildren(header, [name, icon])
    builder.setAttribute(header, kAXTitleAttribute as String, "GM Device 5")
    builder.setAttribute(name, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(name, kAXValueAttribute as String, "GM Device 5")
    // Adversarial: an "Audio" signal that would otherwise win the `.audio`
    // branch. The gm-device branch must take precedence.
    builder.setAttribute(icon, kAXDescriptionAttribute as String, "Audio Channel Strip")

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 5, runtime: runtime)

    #expect(track.name == "GM Device 5")
    #expect(track.type == .externalMIDI)
}

@Test func testAXValueExtractorsPreferTrackTextFieldDescriptionOverStaticText() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(230)
    let staticName = builder.element(231)
    let editableName = builder.element(232)

    builder.setChildren(header, [staticName, editableName])
    builder.setAttribute(staticName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(staticName, kAXValueAttribute as String, "Old Label")
    builder.setAttribute(editableName, kAXRoleAttribute as String, kAXTextFieldRole as String)
    builder.setAttribute(editableName, kAXDescriptionAttribute as String, "Live Label")
    builder.setAttribute(editableName, kAXValueAttribute as String, 0)

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime)

    #expect(track.name == "Live Label")
}

@Test func testAXValueExtractorsInfersTrackTypeFromHeaderDescendants() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(240)
    let name = builder.element(241)
    let icon = builder.element(242)

    builder.setChildren(header, [name, icon])
    builder.setAttribute(header, kAXDescriptionAttribute as String, "1개의 ‘Clean Echoes’ 트랙")
    builder.setAttribute(name, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(name, kAXValueAttribute as String, "Clean Echoes")
    builder.setAttribute(icon, kAXDescriptionAttribute as String, "Software Instrument Track")

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime)

    #expect(track.name == "Clean Echoes")
    #expect(track.type == .softwareInstrument)
}

@Test func testAXValueExtractorsTransportSupportsLoopClickAndHeuristicFields() {
    let builder = FakeAXRuntimeBuilder()
    let transport = builder.element(30)
    let recordArm = builder.element(31)
    let loop = builder.element(32)
    let click = builder.element(33)
    let dottedPosition = builder.element(34)
    let timecode = builder.element(35)
    let invalidTempo = builder.element(36)

    builder.setChildren(transport, [recordArm, loop, click, dottedPosition, timecode, invalidTempo])

    builder.setAttribute(recordArm, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(recordArm, kAXDescriptionAttribute as String, "Record Arm")
    builder.setAttribute(recordArm, kAXValueAttribute as String, 1)

    builder.setAttribute(loop, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(loop, kAXDescriptionAttribute as String, "Loop")
    builder.setAttribute(loop, kAXValueAttribute as String, 1)

    builder.setAttribute(click, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(click, kAXDescriptionAttribute as String, "Click")
    builder.setAttribute(click, kAXValueAttribute as String, 1)

    builder.setAttribute(dottedPosition, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(dottedPosition, kAXValueAttribute as String, "17.2.1")

    builder.setAttribute(timecode, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(timecode, kAXValueAttribute as String, "01:02:03:04")

    builder.setAttribute(invalidTempo, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(invalidTempo, kAXDescriptionAttribute as String, "Tempo")
    builder.setAttribute(invalidTempo, kAXValueAttribute as String, "fast BPM")

    let runtime = builder.makeAXRuntime()
    let state = AXValueExtractors.extractTransportState(from: transport, runtime: runtime)

    #expect(!(state.isRecording))
    #expect(state.isCycleEnabled)
    #expect(state.isMetronomeEnabled)
    #expect(state.position == "17.2.1")
    #expect(state.timePosition == "01:02:03:04")
    #expect(state.tempo == 120.0)
}
