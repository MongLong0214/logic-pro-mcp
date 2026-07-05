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
    let plain = builder.element(1)
    let accented = builder.element(2)
    builder.setAttribute(plain, kAXTitleAttribute as String, "Audio 1")
    builder.setAttribute(accented, kAXTitleAttribute as String, "áudio 1")

    let runtime = builder.makeAXRuntime()

    #expect(AXValueExtractors.extractTrackState(from: plain, index: 0, runtime: runtime).type == .audio)
    #expect(AXValueExtractors.extractTrackState(from: accented, index: 1, runtime: runtime).type == .unknown)
}
