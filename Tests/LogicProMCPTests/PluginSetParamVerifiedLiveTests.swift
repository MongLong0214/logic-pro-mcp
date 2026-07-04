@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// T5 — logic_plugins.set_param_verified LIVE write/readback path (R6 steps 6-13)
// for the FIRST verified-writable parameter, Compressor `threshold` (normalized
// %. Deterministic via
// FakeAXRuntimeBuilder + an injected plugin-window opener; no running Logic Pro.
//
// The fixture wires the full AX tree the live path walks:
//   app
//     ├─ AXWindows = [arrangeWindow, pluginWindow]
//   arrangeWindow ── trackHeaders group (AXSelected rows) + mixer (strips/slots)
//   pluginWindow  (title = track name) ── Threshold AXSlider (AXValue + valueDesc)
//
// Coverage:
//   - State A (before 51 → set 60 → after 60, within tolerance)
//   - tolerance edge (within → A, outside → C readback_mismatch + rollback)
//   - window not found → window_open_failed (and opener fallback → A)
//   - slider not found → param_control_not_found
//   - other param (Gain, capability .unsupported) → unsupported_param_readback

private let expectedPath = "/Users/me/Music/AcidWashBass copy.logicx"
private let trackName = "Acid Wash Bass"

// MARK: - Fixture

/// A live-path fixture. The slider's AXValueDescription is recomputed from its
/// AXValue on every write so a write updates the readback the way Logic does
/// ("60 %"). `forcedAfterValue` models a sticky/taper mismatch; `otherTracks`
/// pads the header/strip count so a non-zero target track index is realistic.
private final class LiveFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let runtime: AXLogicProElements.Runtime

    init(
        track: Int = 0,
        insert: Int = 6,
        trackSelected: Bool = true,
        thresholdDescription: String = "Threshold",
        beforeValue: Double = 51,
        pluginWindowPresent: Bool = true,
        forcedAfterValue: Double? = nil,
        otherTracks: Int = 0,
        emptyInsertChain: Bool = false
    ) {
        let b = builder
        let app = b.element(1000)
        let arrangeWindow = b.element(1001)
        let headersGroup = b.element(1002)
        let mixer = b.element(1003)
        let pluginWindow = b.element(1004)
        let slider = b.element(1005)

        // --- Track headers: one row per track, selected-state on the target. ---
        var headerRows: [AXUIElement] = []
        let rowCount = max(track + 1, otherTracks + 1)
        for i in 0..<rowCount {
            let row = b.element(1100 + i)
            b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            // Track name is surfaced via the header's AXDescription (quoted),
            // matching how extractTrackName reads live Logic headers.
            b.setAttribute(row, kAXDescriptionAttribute as String, "1개의 ‘\(i == track ? trackName : "Other \(i)")’ 트랙")
            b.setAttribute(row, kAXSelectedAttribute as String, (i == track && trackSelected))
            headerRows.append(row)
        }
        b.setAttribute(headersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(headersGroup, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setChildren(headersGroup, headerRows)

        // --- Mixer: one strip per track; target strip carries occupied inserts
        //     up to `insert` so audioPluginInsertSlots reports it occupied. ---
        var strips: [AXUIElement] = []
        for i in 0..<rowCount {
            let strip = b.element(1200 + i)
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            if i == track {
                if emptyInsertChain {
                    // #234 — a Master/VCA-shaped target strip that exposes zero
                    // enumerable insert slots, to exercise the slot-addressing
                    // guard's zero-slot branch.
                    b.setChildren(strip, masterShapedStripChildren(b, base: 1500))
                } else {
                    var slots: [AXUIElement] = []
                    for s in 0...insert {
                        slots.append(LiveFixture.occupiedSlot(b, 1300 + s, name: s == insert ? "Compressor" : "Plugin \(s)"))
                    }
                    b.setChildren(strip, slots)
                }
            } else {
                b.setChildren(strip, [LiveFixture.emptySlot(b, 1400 + i)])
            }
            strips.append(strip)
        }
        b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(mixer, strips)

        // --- Arrange window holds both the headers group and the mixer. ---
        b.setAttribute(arrangeWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(arrangeWindow, kAXTitleAttribute as String, "AcidWashBass — Tracks")
        b.setChildren(arrangeWindow, [headersGroup, mixer])

        // --- Plugin window: title == track name; one Threshold AXSlider. ---
        b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(slider, kAXDescriptionAttribute as String, thresholdDescription)
        b.setAttribute(slider, kAXValueAttribute as String, beforeValue)
        b.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
        b.setAttribute(slider, kAXMaxValueAttribute as String, 100.0)
        b.setAttribute(slider, kAXValueDescriptionAttribute as String, "\(Int(beforeValue)) %")
        b.setAttribute(pluginWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(pluginWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(pluginWindow, kAXTitleAttribute as String, trackName)
        b.setChildren(pluginWindow, [slider])

        let windows = pluginWindowPresent ? [arrangeWindow, pluginWindow] : [arrangeWindow]
        b.setAttribute(app, kAXWindowsAttribute as String, windows)
        // mainWindow fallback target (used if AXWindows is ever empty).
        b.setAttribute(app, kAXMainWindowAttribute as String, arrangeWindow)

        // Intercept AXValue writes so AXValueDescription tracks the new value the
        // way Logic re-renders it ("X %") and an optional forced value models a
        // sticky parameter (readback != requested).
        let sliderKey = b.elementID(slider)
        let forced = forcedAfterValue
        let runtime = b.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { [b] el, attribute, value in
                guard b.elementID(el) == sliderKey, attribute == (kAXValueAttribute as String) else {
                    b.setAttribute(el, attribute, value)
                    return true
                }
                let requested = (value as? NSNumber)?.doubleValue ?? 0
                let landed = forced ?? requested
                b.setAttribute(el, kAXValueAttribute as String, landed)
                b.setAttribute(el, kAXValueDescriptionAttribute as String, "\(Int(landed.rounded())) %")
                return true
            },
            performActionHandler: nil
        )
        self.runtime = runtime
    }

    private static func occupiedSlot(_ b: FakeAXRuntimeBuilder, _ id: Int, name: String) -> AXUIElement {
        let group = b.element(id)
        let bypass = b.element(id * 10 + 1)
        let open = b.element(id * 10 + 2)
        b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(group, kAXDescriptionAttribute as String, name)
        b.setChildren(group, [bypass, open])
        b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
        b.setAttribute(bypass, kAXValueAttribute as String, 0)
        b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
        return group
    }

    private static func emptySlot(_ b: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
        let el = b.element(id)
        b.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(el, kAXDescriptionAttribute as String, "오디오 플러그인")
        b.setAttribute(el, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
        return el
    }

    var currentSliderValue: Double? {
        builder.attributeValue(builder.element(1005), kAXValueAttribute as String) as? Double
    }
}

private func runLive(
    fixture: LiveFixture,
    params: [String: String],
    frontDoc: String? = expectedPath,
    opener: @escaping AccessibilityChannel.PluginWindowOpener = { _, _ in nil }
) async -> [String: Any] {
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: params,
        runtime: fixture.runtime,
        frontDocumentPath: { frontDoc },
        pluginWindowOpener: opener
    )
    return try! JSONSerialization.jsonObject(
        with: result.message.data(using: .utf8)!, options: []
    ) as! [String: Any]
}

private func thresholdParams(
    track: Int = 0,
    insert: Int = 6,
    value: String = "60",
    unit: String = "normalized",
    mode: String = "duplicate_applyback",
    path: String? = expectedPath
) -> [String: String] {
    var p: [String: String] = [
        "track": String(track), "insert": String(insert),
        "plugin": "Compressor", "param": "threshold",
        "value": value, "unit": unit, "mode": mode,
    ]
    if let path { p["project_expected_path"] = path }
    return p
}

// MARK: - State A: full round-trip (before 51 → set 60 → after 60)

@Test func testCompressorThresholdVerifiedWriteReachesStateA() async {
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    #expect(obj["state"] as? String == "A")
    #expect((obj["verified"] as? Bool)!)
    #expect((obj["success"] as? Bool)!)
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(obj["requested_normalized"] as? Double == 60)
    #expect(obj["observed_normalized"] as? Double == 60)
    #expect(obj["observed_display"] as? String == "60 %")
    #expect(obj["display_unit"] as? String == "%")
    #expect(obj["tolerance"] as? Double == 1.0)
    #expect(obj["write_source"] as? String == "ax_plugin_window")
    #expect(obj["verify_source"] as? String == "ax_plugin_window")
    let identity = obj["target_identity"] as? [String: Any]
    #expect(identity?["plugin_id"] as? String == "logic.stock.effect.compressor")
    #expect(identity?["track_index"] as? Int == 0)
    #expect(identity?["insert"] as? Int == 6)
    // The live slider actually changed.
    #expect(fixture.currentSliderValue == 60)
}

@Test func testWithinToleranceStillStateA() async {
    // forcedAfter 60.7 vs requested 60 → |0.7| <= 1.0 → State A.
    let fixture = LiveFixture(beforeValue: 51, forcedAfterValue: 60.7)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "60"))
    #expect(obj["state"] as? String == "A")
    #expect(obj["observed_normalized"] as? Double == 60.7)
}

// MARK: - State C: tolerance exceeded → readback_mismatch + rollback

@Test func testOutsideToleranceIsReadbackMismatchAndRollsBack() async {
    // Slider sticks at 40 regardless of the requested 60 → |40-60| = 20 > 1.0.
    let fixture = LiveFixture(beforeValue: 51, forcedAfterValue: 40)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect(!((obj["verified"] as? Bool)!))
    #expect((obj["write_attempted"] as? Bool)!)
    #expect(obj["requested_normalized"] as? Double == 60)
    #expect(obj["observed_normalized"] as? Double == 40)
    #expect(obj["tolerance"] as? Double == 1.0)
    // Rollback re-set to the before value (51). Because the slider is forced to
    // 40 on every write, the re-read returns 40, so rollback is attempted but
    // does not confirm — the honest report says attempted:true, succeeded:false.
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect(obj["rollback_to"] as? Double == 51)
}

@Test func testRollbackSucceedsWhenWriteIsHonest() async {
    // No forced value: the rollback write to 51 actually lands, so the re-read
    // confirms it. We still get readback_mismatch because the FIRST write (to
    // an out-of-range requested value) is what mismatches — drive that via a
    // requested value the slider cannot reach by clamping through forced=nil but
    // a requested value far from before. Instead, model a slider that lands the
    // requested value, then assert a mismatch using a tolerance-busting target.
    // Simpler: forced value equals a near-miss only on the FIRST write.
    let fixture = OneShotStickyFixture(beforeValue: 51, firstWriteLandsAt: 40)
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: thresholdParams(value: "60"),
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath }
    )
    let obj = try! JSONSerialization.jsonObject(with: result.message.data(using: .utf8)!) as! [String: Any]
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect((obj["rollback_succeeded"] as? Bool)!, "the rollback write to 51 lands and is confirmed")
    #expect(fixture.currentSliderValue == 51)
}

// MARK: - State C: window not found → window_open_failed

@Test func testNoOpenPluginWindowIsWindowOpenFailed() async {
    let fixture = LiveFixture(beforeValue: 51, pluginWindowPresent: false)
    let obj = await runLive(fixture: fixture, params: thresholdParams())
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_open_failed")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testOpenerFallbackProducesStateA() async {
    // No already-open window, but the injected opener supplies one → write
    // proceeds to State A. Proves step 8b is wired.
    let fixture = LiveFixture(beforeValue: 51, pluginWindowPresent: false)
    // Build a standalone window element with the Threshold slider for the opener.
    let b = fixture.builder
    let openedWindow = b.element(2000)
    let openedSlider = b.element(2001)
    b.setAttribute(openedSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(openedSlider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(openedSlider, kAXValueAttribute as String, 51.0)
    b.setAttribute(openedSlider, kAXValueDescriptionAttribute as String, "51 %")
    b.setAttribute(openedWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(openedWindow, kAXTitleAttribute as String, trackName)
    b.setChildren(openedWindow, [openedSlider])
    let sendable = AXUIElementSendable(openedWindow)

    let obj = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        opener: { name, desc in
            (name == trackName && desc == "Threshold") ? sendable : nil
        }
    )
    #expect(obj["state"] as? String == "A", "opener-supplied window must allow the write")
    #expect(obj["observed_normalized"] as? Double == 60)
}

// MARK: - State C: slider not found → param_control_not_found

@Test func testWindowWithoutMatchingSliderIsParamControlNotFound() async {
    // The window exists and is titled with the track name, but its only slider
    // carries a DIFFERENT description, so the "already open" lookup skips it AND
    // the opener returns a window whose slider still cannot be matched.
    let fixture = LiveFixture(thresholdDescription: "슬라이더", beforeValue: 51, pluginWindowPresent: true)
    // openPluginWindow requires BOTH title match AND matching slider — with a
    // non-matching slider the already-open lookup fails, so route through an
    // opener that returns the very same (non-matching) window to reach step 9.
    let b = fixture.builder
    let mismatchWindow = b.element(2100)
    let mismatchSlider = b.element(2101)
    b.setAttribute(mismatchSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(mismatchSlider, kAXDescriptionAttribute as String, "슬라이더")
    b.setAttribute(mismatchWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(mismatchWindow, kAXTitleAttribute as String, trackName)
    b.setChildren(mismatchWindow, [mismatchSlider])
    let sendable = AXUIElementSendable(mismatchWindow)

    let obj = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        opener: { _, _ in sendable }
    )
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "param_control_not_found")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - State C: track not selectable → track_selection_failed

@Test func testTrackNotVerifiedSelectedIsTrackSelectionFailed() async {
    // Header never reads back as AXSelected → step-6 verification fails.
    let fixture = LiveFixture(trackSelected: false, beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams())
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "track_selection_failed")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - State C: target insert empty → incomplete_inventory

@Test func testEmptyTargetSlotIsIncompleteInventory() async {
    // insert 6 is occupied in the fixture; request insert 0 which is also
    // occupied. To hit "empty target", ask for a slot beyond the occupied chain.
    let fixture = LiveFixture(insert: 3) // slots 0..3 occupied
    let obj = await runLive(fixture: fixture, params: thresholdParams(insert: 5))
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "incomplete_inventory")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - #234 zero-slot slot-addressing diagnostics (AC-5 / boomer R2-#2)

@Test func testSetParamVerifiedZeroSlotsStateCDistinctDiagnostics() async {
    // A zero-slot (Master-shaped) target strip through set_param_verified's slot-
    // addressing guard. Pre-#234 the guard reported the bare "insert N is out of
    // range (0 slots)"; now it names the insert_section_not_enumerable condition
    // and carries the recovery hint. Still State C with its existing
    // incomplete_inventory code — the write path never softens to State B — and no
    // write is attempted.
    let fixture = LiveFixture(beforeValue: 51, emptyInsertChain: true)
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "incomplete_inventory")
    #expect(!((obj["write_attempted"] as? Bool)!))
    let observed = (obj["what_was_observed"] as? String) ?? ""
    #expect(observed.contains("no enumerable insert slots"))
    let hint = (obj["recovery_hint"] as? String) ?? ""
    #expect(hint.contains("Master"))
    #expect(fixture.currentSliderValue == 51, "no write may occur when the slot cannot be addressed")
}

// MARK: - Other parameter (Gain) stays unsupported (no write)

@Test func testGainStillUnsupportedNoWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: [
        "track": "0", "insert": "6", "plugin": "Gain", "param": "gain_db",
        "value": "-4", "unit": "dB", "mode": "duplicate_applyback",
        "project_expected_path": expectedPath,
    ])
    #expect(obj["error"] as? String == "unsupported_param_readback")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - Precedence: wrong unit / out-of-range still beat the live write

@Test func testThresholdWrongUnitIsInvalidParamsBeforeWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: thresholdParams(unit: "dB"))
    #expect(obj["error"] as? String == "invalid_params")
}

@Test func testThresholdOutOfRangeIsInvalidParamsBeforeWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "150"))
    #expect(obj["error"] as? String == "invalid_params")
    #expect(fixture.currentSliderValue == 51, "no write may occur on a range violation")
}

@Test func testThresholdConfirmedLiveBlockedBeforeWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: thresholdParams(mode: "confirmed_live"))
    #expect(obj["error"] as? String == "unsupported_mode")
    #expect(fixture.currentSliderValue == 51)
}

// MARK: - A fixture whose slider is sticky on the FIRST write only

/// Models a slider that lands the FIRST write at `firstWriteLandsAt` (forcing a
/// mismatch) but honours every subsequent write (so the rollback to `before`
/// confirms). Lets us assert rollback_succeeded:true distinctly from the
/// permanently-sticky case.
private final class OneShotStickyFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let runtime: AXLogicProElements.Runtime
    private let writeCount = Counter()

    init(beforeValue: Double, firstWriteLandsAt: Double) {
        let b = builder
        let app = b.element(3000)
        let arrangeWindow = b.element(3001)
        let headersGroup = b.element(3002)
        let mixer = b.element(3003)
        let pluginWindow = b.element(3004)
        let slider = b.element(3005)

        let row = b.element(3100)
        b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setAttribute(row, kAXDescriptionAttribute as String, "1개의 ‘\(trackName)’ 트랙")
        b.setAttribute(row, kAXSelectedAttribute as String, true)
        b.setAttribute(headersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(headersGroup, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setChildren(headersGroup, [row])

        let strip = b.element(3200)
        b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        var slots: [AXUIElement] = []
        for s in 0...6 {
            let g = b.element(3300 + s)
            let by = b.element((3300 + s) * 10 + 1)
            let op = b.element((3300 + s) * 10 + 2)
            b.setAttribute(g, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(g, kAXDescriptionAttribute as String, s == 6 ? "Compressor" : "P\(s)")
            b.setChildren(g, [by, op])
            b.setAttribute(by, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            b.setAttribute(by, kAXDescriptionAttribute as String, "바이패스")
            b.setAttribute(by, kAXValueAttribute as String, 0)
            b.setAttribute(op, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(op, kAXDescriptionAttribute as String, "열기")
            slots.append(g)
        }
        b.setChildren(strip, slots)
        b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(mixer, [strip])

        b.setAttribute(arrangeWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setChildren(arrangeWindow, [headersGroup, mixer])

        b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(slider, kAXDescriptionAttribute as String, "Threshold")
        b.setAttribute(slider, kAXValueAttribute as String, beforeValue)
        b.setAttribute(slider, kAXValueDescriptionAttribute as String, "\(Int(beforeValue)) %")
        b.setAttribute(pluginWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(pluginWindow, kAXTitleAttribute as String, trackName)
        b.setChildren(pluginWindow, [slider])

        b.setAttribute(app, kAXWindowsAttribute as String, [arrangeWindow, pluginWindow])
        b.setAttribute(app, kAXMainWindowAttribute as String, arrangeWindow)

        let sliderKey = b.elementID(slider)
        let counter = writeCount
        self.runtime = b.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { [b] el, attribute, value in
                guard b.elementID(el) == sliderKey, attribute == (kAXValueAttribute as String) else {
                    b.setAttribute(el, attribute, value)
                    return true
                }
                let requested = (value as? NSNumber)?.doubleValue ?? 0
                let n = counter.next()
                let landed = n == 1 ? firstWriteLandsAt : requested
                b.setAttribute(el, kAXValueAttribute as String, landed)
                b.setAttribute(el, kAXValueDescriptionAttribute as String, "\(Int(landed.rounded())) %")
                return true
            },
            performActionHandler: nil
        )
    }

    var currentSliderValue: Double? {
        builder.attributeValue(builder.element(3005), kAXValueAttribute as String) as? Double
    }
}

/// Tiny serial counter for the one-shot fixture (the AX runtime closure is
/// @Sendable so a class with a lock keeps it Sendable-safe under --no-parallel).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}
