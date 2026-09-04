@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Per-operation tests for Honest Contract 3-state behaviour.
// Covers T2 (set_instrument), T3 (track.select), T5 (set_cycle_range).
// Live-AX-dependent paths (actual Logic Pro running) are marked `.disabled`.

// MARK: - Helpers

private func decodeJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

// MARK: - T3 track.select

@Test func testTrackSelectReturnsVerifiedTrueWhenSelectedChildMatches() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(700)
    let window = builder.element(701)
    let trackList = builder.element(702)
    let header0 = builder.element(703)
    let header1 = builder.element(704)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [header0, header1])
    builder.setAttribute(header0, kAXTitleAttribute as String, "Track 1")
    builder.setAttribute(header0, kAXSelectedAttribute as String, false)
    builder.setAttribute(header1, kAXTitleAttribute as String, "Track 2")
    builder.setAttribute(header1, kAXSelectedAttribute as String, true)

    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let result = await channel.execute(operation: "track.select", params: ["index": "1"])
    let obj = decodeJSON(result.message)
    #expect(result.isSuccess)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["requested"] as? Int == 1)
    #expect(obj["observed"] as? Int == 1)
}

@Test func testTrackSelectReturnsStateCWhenHeaderMissing() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(710)
    let window = builder.element(711)
    let trackList = builder.element(712)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [])

    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let result = await channel.execute(operation: "track.select", params: ["index": "5"])
    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "element_not_found")
    #expect(obj["hint"] != nil)
}

@Test func testTrackSelectReturnsStateBReadbackMismatchOnMismatch() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(720)
    let window = builder.element(721)
    let trackList = builder.element(722)
    let h0 = builder.element(723)
    let h1 = builder.element(724)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [h0, h1])
    builder.setAttribute(h0, kAXTitleAttribute as String, "Track 1")
    builder.setAttribute(h0, kAXSelectedAttribute as String, true) // stays on 0
    builder.setAttribute(h1, kAXTitleAttribute as String, "Track 2")
    builder.setAttribute(h1, kAXSelectedAttribute as String, false)

    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let result = await channel.execute(operation: "track.select", params: ["index": "1"])
    #expect(result.isSuccess, "mismatch is State B (success:true, verified:false)")
    let obj = decodeJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    // v3.1.0 (Ralph-2 / P2-2) — mismatch is readback_mismatch, not
    // retry_exhausted. The latter is reserved for selectionMetadataUnavailable.
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["requested"] as? Int == 1)
    #expect(obj["observed"] as? Int == 0)
}

// MARK: - T2 set_instrument — read-back logic (pure function level)
//
// The full mutating handler requires a live Logic Pro AX tree (AXBrowser →
// AXList → AXStaticText). We cover the read-back helper directly; end-to-end
// verification is Phase 2 live-gated.

@Test func testLibraryReadBackReturnsNilWhenNoBrowserPresent() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(730)
    let window = builder.element(731)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [])

    let rt = builder.makeLogicRuntime(appElement: app)
    let observed = AccessibilityChannel.readBackLibraryPreset(runtime: rt)
    #expect(observed == nil, "no library browser → readback_unavailable signal")
}

// MARK: - T5 set_cycle_range
//
// AX-path read-back is exercised through `defaultSetCycleRange`. When the
// transport bar doesn't expose numeric locator fields we must fail closed with
// a structured State C payload instead of letting the router wrap a free-form
// string in `channels_exhausted`.

@Test func testSetCycleRangeReturnsErrorWhenNoTransportFields() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(740)
    let window = builder.element(741)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [])

    let runtime = builder.makeLogicRuntime(appElement: app)
    let res = AccessibilityChannel.defaultSetCycleRange(
        params: ["start": "1", "end": "5"],
        runtime: runtime,
        runFallback: { _, _ in false }
    )
    #expect(!res.isSuccess, "No transport bar + no fallback → structured State C")
    let obj = decodeJSON(res.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "not_implemented")
    #expect(obj["operation"] as? String == "transport.set_cycle_range")
    #expect(obj["method"] as? String == "ax_cycle_locator_text_fields")
    #expect(obj["requested"] as? [String: Any] != nil)
    #expect(obj["observed"] as? [String: Any] != nil)
    #expect(obj["scanned_landmarks"] as? [String: Any] != nil)
    #expect(!((obj["safe_to_retry"] as? Bool)!))
}

@Test func testSetCycleRangeOsascriptFallbackFailsClosedWithoutReadback() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(750)
    let window = builder.element(751)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [])

    let runtime = builder.makeLogicRuntime(appElement: app)
    let res = AccessibilityChannel.defaultSetCycleRange(
        params: ["start": "1", "end": "5"],
        runtime: runtime,
        runFallback: { _, _ in true }
    )
    #expect(!res.isSuccess)
    let obj = decodeJSON(res.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "readback_unavailable")
    #expect(obj["method"] as? String == "osascript_set_locators_dialog")
    #expect((obj["write_attempted"] as? Bool)!)
    #expect(obj["observed"] as? [String: Any] != nil)
}

// MARK: - T-3 (v3.1.1): track.rename — HC envelope

@Test func testTrackRenameMissingParamsReturnsStateCInvalidParams() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(800)
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let result = await channel.execute(operation: "track.rename", params: ["index": "0"])
    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "invalid_params")
    #expect(obj["hint"] != nil)
}

@Test func testTrackRenameMissingHeaderReturnsStateCElementNotFound() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(810)
    let window = builder.element(811)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [])
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let result = await channel.execute(operation: "track.rename", params: ["index": "0", "name": "Lead"])
    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(obj["error"] as? String == "element_not_found")
    #expect(obj["track"] as? Int == 0)
    #expect(obj["requested"] as? String == "Lead")
}

// MARK: - T-3 (v3.1.1): track.set_mute/solo/arm — HC envelope

@Test func testTrackSetMuteMissingHeaderReturnsErrorMessage() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(820)
    let window = builder.element(821)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [])
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])
    #expect(!result.isSuccess)
    #expect(result.message.contains("Cannot find Mute button"))
}

// MARK: - T-4 (v3.1.2 P2-1): track.set_color — explicit State C `not_implemented`

@Test func testTrackSetColorReturnsNotImplemented() async {
    // The set_color path short-circuits inside the AccessibilityChannel
    // operation switch and never touches the AX tree, so the FakeAX
    // builder can be empty. Only the trust + Logic-running gates need to
    // pass for `execute(...)` to reach the switch statement.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(900)
    let window = builder.element(901)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [])
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let result = await channel.execute(
        operation: "track.set_color",
        params: ["index": "2", "color": "12"]
    )

    // Outer ChannelResult is .error (set_color uses .error for State C),
    // and the embedded message must be a State C envelope with the
    // canonical `not_implemented` error code + a hint.
    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "not_implemented")
    let hint = obj["hint"] as? String ?? ""
    #expect(hint.contains("Track color"), "expected hint to mention Track color, got: \(hint)")

    // The router uses isTerminalStateC to suppress fallback when the
    // primary channel reports an error no other channel can improve on.
    // `not_implemented` is in `terminalErrorCodes`, so this must be true.
    #expect(
        HonestContract.isTerminalStateC(result.message),
        "set_color State C must be classified as terminal so router skips fallback"
    )
}

// MARK: - v3.1.3 backlog #3 — region.move_to_playhead / region.select_last
// State A envelope contract. Detailed pre/post diff scenarios live in
// `AccessibilityChannelRegionStateATests.swift`; this file pins the
// envelope shape (success/verified/required-keys) for the contract review.

private func axPointHC(_ x: CGFloat, _ y: CGFloat) -> AXValue {
    var p = CGPoint(x: x, y: y); return AXValueCreate(.cgPoint, &p)!
}
private func axSizeHC(_ w: CGFloat, _ h: CGFloat) -> AXValue {
    var s = CGSize(width: w, height: h); return AXValueCreate(.cgSize, &s)!
}

@Test func testRegionMoveToPlayheadStateAEnvelope() async {
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let postHelp = "리전은 9 마디 에서 시작하여 11 마디 에서 끝납니다., MIDI 리전."

    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_500)
    let window = builder.element(1_501)
    let headerRail = builder.element(1_502)
    let trackHeader = builder.element(1_503)
    let contentGroup = builder.element(1_504)
    let region = builder.element(1_505)
    let transport = builder.element(1_506)
    let positionText = builder.element(1_507)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, transport, contentGroup])

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "트랙 헤더")
    builder.setChildren(headerRail, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXPositionAttribute as String, axPointHC(0, 100))
    builder.setAttribute(trackHeader, kAXSizeAttribute as String, axSizeHC(200, 40))

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "트랙 콘텐츠")
    builder.setChildren(contentGroup, [region])
    builder.setAttribute(region, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(region, kAXDescriptionAttribute as String, "RegionA")
    builder.setAttribute(region, kAXHelpAttribute as String, preHelp)
    builder.setAttribute(region, kAXPositionAttribute as String, axPointHC(240, 108))
    builder.setAttribute(region, kAXSizeAttribute as String, axSizeHC(320, 24))
    builder.setAttribute(region, kAXSelectedAttribute as String, true)

    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")
    builder.setChildren(transport, [positionText])
    builder.setAttribute(positionText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(positionText, kAXDescriptionAttribute as String, "Position")
    builder.setAttribute(positionText, kAXValueAttribute as String, "9.1.1.1")

    let runtime = builder.makeLogicRuntime(appElement: app)

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: runtime,
        executeScript: { _ in
            builder.setAttribute(region, kAXHelpAttribute as String, postHelp)
            return .success("OK")
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    // State A envelope contract.
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["reason"] == nil, "State A must not carry a reason field")
    #expect(obj["error"] == nil, "State A must not carry an error field")
    // Pre/post diff fields the contract requires.
    #expect(obj["requested"] != nil)
    #expect(obj["observed"] != nil)
    #expect(obj["via"] as? String == "applescript_menu")
}

@Test func testRegionSelectLastStateAEnvelope() async {
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_600)
    let window = builder.element(1_601)
    let headerRail = builder.element(1_602)
    let trackHeader = builder.element(1_603)
    let contentGroup = builder.element(1_604)
    let regionA = builder.element(1_605)
    let regionB = builder.element(1_606)
    let transport = builder.element(1_607)
    let positionText = builder.element(1_608)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, transport, contentGroup])

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "트랙 헤더")
    builder.setChildren(headerRail, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXPositionAttribute as String, axPointHC(0, 100))
    builder.setAttribute(trackHeader, kAXSizeAttribute as String, axSizeHC(200, 40))

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "트랙 콘텐츠")
    builder.setChildren(contentGroup, [regionA, regionB])
    builder.setAttribute(regionA, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(regionA, kAXDescriptionAttribute as String, "A")
    builder.setAttribute(regionA, kAXHelpAttribute as String, regionAHelp)
    builder.setAttribute(regionA, kAXPositionAttribute as String, axPointHC(100, 108))
    builder.setAttribute(regionA, kAXSizeAttribute as String, axSizeHC(160, 24))
    builder.setAttribute(regionA, kAXSelectedAttribute as String, false)
    builder.setAttribute(regionB, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(regionB, kAXDescriptionAttribute as String, "B")
    builder.setAttribute(regionB, kAXHelpAttribute as String, regionBHelp)
    builder.setAttribute(regionB, kAXPositionAttribute as String, axPointHC(400, 108))
    builder.setAttribute(regionB, kAXSizeAttribute as String, axSizeHC(160, 24))
    builder.setAttribute(regionB, kAXSelectedAttribute as String, false)

    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")
    builder.setChildren(transport, [positionText])
    builder.setAttribute(positionText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(positionText, kAXDescriptionAttribute as String, "Position")
    builder.setAttribute(positionText, kAXValueAttribute as String, "1.1.1.1")

    let runtime = builder.makeLogicRuntime(appElement: app)

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: runtime,
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    // State A envelope contract.
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["reason"] == nil)
    #expect(obj["error"] == nil)
    #expect(obj["expected_name"] as? String == "B")
    #expect(obj["selected_name"] as? String == "B")
    #expect(obj["expected_start_bar"] as? Int == 5)
    #expect(obj["selected_start_bar"] as? Int == 5)
}
