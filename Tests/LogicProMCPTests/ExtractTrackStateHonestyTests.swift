@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

/// WS3 AC2 — `extractTrackState` value-only honesty fix.
///
/// `logic://tracks` previously fabricated `volume = 0.0`, `pan = 0.0`, and
/// `automationMode = .off` for every track. These tests prove the resource now
/// reports the REAL track-header values (RED against the old fabrication) while
/// the `TrackState` type stays byte-identical: the fields remain non-optional
/// `Double`/`Double`/`AutomationMode` with no sentinel, no nullable, and no new
/// enum case. They also lock the "retain the pre-fix default on a rare AX-read
/// failure" contract so no NEW unreadable representation is introduced.
///
/// Unit fixtures use a fake track-header exposing known values; the live
/// taper/structure on Logic 12.3 is covered by integration live-verify.

/// A track header carrying a real volume fader (contract 0.75) and a real pan
/// slider (contract -0.5) flows both through `extractTrackState` — no longer 0.0.
@Test func testExtractTrackStateReadsRealHeaderVolumeAndPan() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let volumeFader = builder.element(2)
    let panSlider = builder.element(3)
    let panIndicator = builder.element(4)

    builder.setChildren(header, [volumeFader, panSlider])
    builder.setChildren(panSlider, [panIndicator])

    // Volume fader: own description carries "Volume" so it is identified as the
    // fader (not the pan slider). Range 0...1 is NOT a raw Logic fader range, so
    // `extractLogicMixerFaderValue` returns the fader position directly (0.75).
    builder.setAttribute(volumeFader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(volumeFader, kAXDescriptionAttribute as String, "Volume")
    builder.setAttribute(volumeFader, kAXValueAttribute as String, 0.75)
    builder.setAttribute(volumeFader, kAXMinValueAttribute as String, 0.0)
    builder.setAttribute(volumeFader, kAXMaxValueAttribute as String, 1.0)

    // Pan slider: identified by a child value-indicator described "Pan". Live
    // header pan range is 0...128 with electrical center at the midpoint, so
    // raw 32 maps to the -1.0...1.0 contract at -0.5.
    builder.setAttribute(panSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(panSlider, kAXValueAttribute as String, 32.0)
    builder.setAttribute(panSlider, kAXMinValueAttribute as String, 0.0)
    builder.setAttribute(panSlider, kAXMaxValueAttribute as String, 128.0)
    builder.setAttribute(panIndicator, kAXDescriptionAttribute as String, "Pan")

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 2, runtime: runtime)

    #expect(track.volume == 0.75)
    #expect(track.pan == -0.5)
    // De-fabrication guard: the pre-fix code hard-coded both to 0.0.
    #expect(track.volume != 0.0)
    #expect(track.pan != 0.0)
}

/// A raw Logic mixer fader range (0...233) is mapped through the mixer volume
/// taper — the SAME contract the #107 write path and `logic://mixer` speak — so
/// `logic://tracks` volume agrees with the mixer instead of reporting raw AX.
@Test func testExtractTrackStateMapsRawFaderRangeThroughMixerTaper() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let volumeFader = builder.element(2)

    builder.setChildren(header, [volumeFader])
    builder.setAttribute(volumeFader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(volumeFader, kAXDescriptionAttribute as String, "Volume")
    builder.setAttribute(volumeFader, kAXValueAttribute as String, 70.0)
    builder.setAttribute(volumeFader, kAXMinValueAttribute as String, 0.0)
    builder.setAttribute(volumeFader, kAXMaxValueAttribute as String, 233.0)

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime)

    // 70/233 is a calibrated taper point that maps to the 0.4 contract value.
    #expect(abs(track.volume - 0.4) < 1e-9)
}

/// When the header exposes no fader, pan slider, or automation control, each
/// reader RETAINS the pre-fix default (0.0 / 0.0 / .off) — no new unreadable
/// representation (no NaN/sentinel/nullable) is introduced.
@Test func testExtractTrackStateRetainsPreFixDefaultsOnUnreadableHeader() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let name = builder.element(2)

    builder.setChildren(header, [name])
    builder.setAttribute(header, kAXTitleAttribute as String, "Bare Track")
    builder.setAttribute(name, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(name, kAXValueAttribute as String, "Bare Track")

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 4, runtime: runtime)

    #expect(track.volume == 0.0)
    #expect(track.pan == 0.0)
    #expect(track.automationMode == .off)
    #expect(AXValueExtractors.extractTrackAutomationModeIfReadable(
        from: header,
        runtime: runtime
    ) == nil)
}

/// The automation mode is read from the track-header automation control's
/// description, mapping each mode token (EN + KO) to the existing enum case.
@Test func testExtractTrackStateReadsAutomationModeFromHeaderControl() {
    func mode(forDescription description: String) -> AutomationMode {
        let builder = FakeAXRuntimeBuilder()
        let header = builder.element(1)
        let automationGroup = builder.element(2)
        builder.setChildren(header, [automationGroup])
        builder.setAttribute(automationGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(automationGroup, kAXDescriptionAttribute as String, description)
        return AXValueExtractors.extractTrackState(
            from: header, index: 0, runtime: builder.makeAXRuntime()
        ).automationMode
    }

    #expect(mode(forDescription: "Automation: Read") == .read)
    #expect(mode(forDescription: "Automation: Touch") == .touch)
    #expect(mode(forDescription: "Automation: Latch") == .latch)
    #expect(mode(forDescription: "Automation: Write") == .write)
    #expect(mode(forDescription: "Automation: Trim") == .trim)
    // Automation control present but Off → .off (no mode token).
    #expect(mode(forDescription: "Automation: Off") == .off)
    // Korean automation control ("오토메이션" context + "읽기" = Read).
    #expect(mode(forDescription: "오토메이션 읽기") == .read)

    let explicitOffBuilder = FakeAXRuntimeBuilder()
    let explicitOffHeader = explicitOffBuilder.element(10)
    let explicitOff = explicitOffBuilder.element(11)
    explicitOffBuilder.setChildren(explicitOffHeader, [explicitOff])
    explicitOffBuilder.setAttribute(
        explicitOff,
        kAXRoleAttribute as String,
        kAXGroupRole as String
    )
    explicitOffBuilder.setAttribute(
        explicitOff,
        kAXDescriptionAttribute as String,
        "Automation: Off"
    )
    #expect(AXValueExtractors.extractTrackAutomationModeIfReadable(
        from: explicitOffHeader,
        runtime: explicitOffBuilder.makeAXRuntime()
    ) == .off)
}

@Test func testAutomationVerificationIgnoresTrackNameSpoofing() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let name = builder.element(2)
    let automationGroup = builder.element(3)
    builder.setChildren(header, [name, automationGroup])
    builder.setAttribute(header, kAXTitleAttribute as String, "Automation Read")
    builder.setAttribute(name, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(name, kAXValueAttribute as String, "Automation Read")
    builder.setAttribute(automationGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(
        automationGroup,
        kAXDescriptionAttribute as String,
        "Automation: Write"
    )

    #expect(AXValueExtractors.extractTrackAutomationModeIfReadable(
        from: header,
        runtime: builder.makeAXRuntime()
    ) == .write)
}

@Test func testAutomationVerificationRejectsUnrelatedControlSpoofing() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let unrelatedButton = builder.element(2)
    builder.setChildren(header, [unrelatedButton])
    builder.setAttribute(unrelatedButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(
        unrelatedButton,
        kAXTitleAttribute as String,
        "Automation Read"
    )

    #expect(AXValueExtractors.extractTrackAutomationModeIfReadable(
        from: header,
        runtime: builder.makeAXRuntime()
    ) == nil)
}

@Test func testAutomationVerificationRejectsConflictingControlMetadata() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let automationGroup = builder.element(2)
    builder.setChildren(header, [automationGroup])
    builder.setAttribute(automationGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(
        automationGroup,
        kAXDescriptionAttribute as String,
        "Automation: Write"
    )
    builder.setAttribute(automationGroup, kAXValueAttribute as String, "Read")

    #expect(AXValueExtractors.extractTrackAutomationModeIfReadable(
        from: header,
        runtime: builder.makeAXRuntime()
    ) == nil)
}

/// The automation read is GATED by the "automation"/"오토메이션" context token:
/// a stray "Read"/"Write" elsewhere in the header (e.g. a record-enable label)
/// must NOT be misread as an automation mode — it stays the .off default.
@Test func testExtractTrackStateAutomationModeGateRejectsStrayModeTokens() {
    let builder = FakeAXRuntimeBuilder()
    let header = builder.element(1)
    let strayControl = builder.element(2)

    builder.setChildren(header, [strayControl])
    builder.setAttribute(strayControl, kAXRoleAttribute as String, kAXButtonRole as String)
    // "read" and "write" appear, but with NO automation context token.
    builder.setAttribute(strayControl, kAXDescriptionAttribute as String, "Read/Write Enable")

    let runtime = builder.makeAXRuntime()
    let track = AXValueExtractors.extractTrackState(from: header, index: 0, runtime: runtime)

    #expect(track.automationMode == .off)
}

/// WS3 AC3 — the track-type LabelSet migration (round-1 #6, 오디오/악기 hoisted
/// into AXLocalePolicy) must preserve DIACRITIC sensitivity: a plain "Audio"
/// header classifies as `.audio`, but an accented-Latin "áudio" header must NOT
/// (folding accents would widen matching in non-EN/KO locales, the #60 hazard).
@Test func testExtractTrackStateTrackTypeClassificationIsDiacriticSensitive() {
    let builder = FakeAXRuntimeBuilder()

    // #766 — the signal sits on a CHILD, not on the header's title. The title is the track name,
    // and the classifier subtracts the name from the aggregate now: a name a user typed is not a
    // reading of what the track is. Carrying the fixture's signal in the name would test that
    // exclusion rather than the diacritic sensitivity this case is about.
    func strip(_ id: Int, signal: String) -> AXUIElement {
        let header = builder.element(id)
        let icon = builder.element(id + 100)
        builder.setAttribute(header, kAXTitleAttribute as String, "Track \(id)")
        builder.setAttribute(icon, kAXDescriptionAttribute as String, signal)
        builder.setChildren(header, [icon])
        return header
    }

    let plain = strip(1, signal: "Audio Channel Strip")
    let accented = strip(2, signal: "áudio Channel Strip")
    let runtime = builder.makeAXRuntime()

    #expect(AXValueExtractors.extractTrackState(from: plain, index: 0, runtime: runtime).type == .audio)
    #expect(AXValueExtractors.extractTrackState(from: accented, index: 1, runtime: runtime).type == .unknown)
}

/// #766 — the attack a review used to break the previous shape of this fix. Subtracting the name
/// from every signal deleted `오디오` out of Logic's own Input Monitoring sentence, so a track
/// renamed exactly `오디오` lost the audio candidate and became a confident `.softwareInstrument`.
/// The header now excludes the attributes that carry the name instead, so renaming a track after
/// a type changes nothing about how it classifies.
@Test func testRenamingATrackAfterATypeCannotFlipItsClassification() {
    let builder = FakeAXRuntimeBuilder()

    // The real header shape: the name lives in the header's AXDescription and in a field's value,
    // and the type tokens live in a Logic-authored help string that names BOTH types.
    func header(named name: String, id: Int) -> AXUIElement {
        let header = builder.element(id)
        let field = builder.element(id + 1)
        let monitoring = builder.element(id + 2)
        builder.setAttribute(header, kAXDescriptionAttribute as String, "1개의 ‘\(name)’ 트랙")
        builder.setAttribute(field, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(field, kAXValueAttribute as String, name)
        builder.setAttribute(monitoring, kAXHelpAttribute as String,
                             "입력 모니터링 버튼. 녹음 활성화가 되지 않은 오디오 또는 소프트웨어 악기 트랙에서")
        builder.setChildren(header, [field, monitoring])
        return header
    }

    let runtime = builder.makeAXRuntime()
    // Both tokens are present in the help, so the honest answer is unknown whatever the name is.
    for (index, name) in ["보통 트랙", "오디오", "악기", "Audio", "Instrument"].enumerated() {
        let element = header(named: name, id: 400 + index * 10)
        let type = AXValueExtractors.extractTrackState(
            from: element, index: index, runtime: runtime
        ).type
        #expect(type == .unknown)
    }
}

/// #766 — a track NAMED after a type is not classified by it. The name is user-editable, and the
/// one branch that still answers confidently is the GM Device guard behind the silent-bounce risk;
/// an outside review found `GM Device scratch` triggering it. Measured live the same day: an audio
/// track renamed that way reads `unknown`, and a real `GM Device 5` strip still reads external MIDI.
@Test func testTrackNamedAfterATypeIsNotClassifiedByItsName() {
    let builder = FakeAXRuntimeBuilder()

    // The real shape, measured 2026-09-04: a track header has NO AXTitle at all — six of six read
    // `<<absent>>` — and the name lives inside typographic quotes in the AXDescription,
    // `27개의 ‘GM Device scratch’ 트랙`. An earlier version of this case put the name in the title,
    // which is not a place Logic uses, and it passed for the wrong reason.
    func header(named name: String, id: Int) -> AXUIElement {
        let element = builder.element(id)
        builder.setAttribute(element, kAXDescriptionAttribute as String, "1개의 ‘\(name)’ 트랙")
        return element
    }

    // The real header carries the name TWICE — the quoted part of its own AXDescription, and the
    // name field's own description, verbatim. Measured on a live header renamed
    // `GM Device scratch`; a fixture with only the first place passed while the product did not.
    func headerWithNameField(named name: String, id: Int) -> AXUIElement {
        let element = builder.element(id)
        let field = builder.element(id + 5)
        builder.setAttribute(element, kAXDescriptionAttribute as String, "27개의 ‘\(name)’ 트랙")
        builder.setAttribute(field, kAXDescriptionAttribute as String, name)
        builder.setAttribute(field, kAXHelpAttribute as String, "이름 필드. 트랙 이름을 변경하려면 두 번 클릭합니다.")
        builder.setChildren(element, [field])
        return element
    }

    let renamedWithField = headerWithNameField(named: "GM Device scratch", id: 30)
    #expect(AXValueExtractors.extractTrackState(
        from: renamedWithField, index: 9, runtime: builder.makeAXRuntime()).type == .unknown)

    let renamed = header(named: "GM Device scratch", id: 20)
    let realGM = header(named: "GM Device 5", id: 21)
    let namedAudio = header(named: "Audio 1", id: 22)

    let runtime = builder.makeAXRuntime()

    #expect(AXValueExtractors.extractTrackState(from: renamed, index: 0, runtime: runtime).type == .unknown)
    #expect(AXValueExtractors.extractTrackState(from: realGM, index: 1, runtime: runtime).type == .externalMIDI)
    #expect(AXValueExtractors.extractTrackState(from: namedAudio, index: 2, runtime: runtime).type == .unknown)
}
