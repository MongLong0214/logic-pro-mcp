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
    #expect(obj["success"] as? Bool == true)
    #expect(obj["verified"] as? Bool == true)
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
    #expect(obj["success"] as? Bool == false)
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
    #expect(obj["verified"] as? Bool == false)
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
// transport bar isn't wired we hit the fallback; when read-back fields are
// absent we return State B `readback_unavailable`.

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
    #expect(!res.isSuccess, "No transport bar + no fallback → hard error")
}

@Test func testSetCycleRangeOsascriptFallbackReturnsStateB() {
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
    #expect(res.isSuccess)
    let obj = decodeJSON(res.message)
    #expect(obj["success"] as? Bool == true)
    #expect(obj["verified"] as? Bool == false)
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect(obj["via"] as? String == "osascript")
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
    #expect(obj["success"] as? Bool == false)
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
