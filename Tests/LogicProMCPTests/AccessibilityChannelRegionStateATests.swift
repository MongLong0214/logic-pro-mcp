@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// v3.1.3 backlog #3 — `region.move_to_playhead` and `region.select_last`
// State A coverage. Both ops were State B (`readback_unavailable`) in v3.1.0
// because the AppleScript-driven menu/click path didn't have a way to verify
// the resulting region position. v3.1.3 adds a pre/post AX snapshot via
// `selectedRegionInfo` + `currentPlayheadBar` (move) and
// `selectedRegionInfo` + `lastRegionInfo` (select_last) so the same
// operations can return State A `verified:true` when read-back matches.

// MARK: - Helpers

private func decodeJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

/// Build a Logic-shaped AX tree with:
///   window
///   ├── headerRail (트랙 헤더) → trackHeaders
///   ├── transport (Transport group) → position static text
///   └── contentGroup (트랙 콘텐츠) → regions (AXLayoutItem)
///
/// `regions` is `(name, help, position, size, selected)`. `headers` is
/// `(position, size)`. `playheadPosition` is the "Bar.Beat.Division.Tick"
/// value extracted from the transport bar.
private struct RegionFakeFixture {
    let builder: FakeAXRuntimeBuilder
    let runtime: AXLogicProElements.Runtime
}

private func makeRegionFixture(
    headers: [(pos: AXValue, size: AXValue)],
    regions: [(name: String, help: String, pos: AXValue, size: AXValue, selected: Bool)],
    playheadPosition: String
) -> RegionFakeFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_000)
    let window = builder.element(1_001)
    let headerRail = builder.element(1_002)
    let contentGroup = builder.element(1_003)
    let transport = builder.element(1_004)
    let positionText = builder.element(1_005)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "트랙 헤더")
    let headerEls: [AXUIElement] = headers.enumerated().map { idx, h in
        let el = builder.element(2_000 + idx)
        builder.setAttribute(el, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(el, kAXPositionAttribute as String, h.pos)
        builder.setAttribute(el, kAXSizeAttribute as String, h.size)
        return el
    }
    builder.setChildren(headerRail, headerEls)

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "트랙 콘텐츠")
    let regionEls: [AXUIElement] = regions.enumerated().map { idx, r in
        let el = builder.element(3_000 + idx)
        builder.setAttribute(el, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(el, kAXDescriptionAttribute as String, r.name)
        builder.setAttribute(el, kAXHelpAttribute as String, r.help)
        builder.setAttribute(el, kAXPositionAttribute as String, r.pos)
        builder.setAttribute(el, kAXSizeAttribute as String, r.size)
        builder.setAttribute(el, kAXSelectedAttribute as String, r.selected)
        return el
    }
    builder.setChildren(contentGroup, regionEls)

    // Transport: matches looksLikeTransportContainer via "Transport" identifier.
    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")
    builder.setAttribute(positionText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(positionText, kAXDescriptionAttribute as String, "Position")
    builder.setAttribute(positionText, kAXValueAttribute as String, playheadPosition)
    builder.setChildren(transport, [positionText])

    builder.setChildren(window, [headerRail, transport, contentGroup])

    return RegionFakeFixture(
        builder: builder,
        runtime: builder.makeLogicRuntime(appElement: app)
    )
}

// MARK: - region.move_to_playhead — State A path

@Test func testMoveToPlayheadReturnsStateAOnMatch() async {
    // Pre: selected region at bar 1. Action moves it to bar 9 (matching
    // playhead). Post-read should expose post.startBar=9 and playhead=9 →
    // State A verified:true.
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let postHelp = "리전은 9 마디 에서 시작하여 11 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: preHelp,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: true
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in
            // Simulate Logic moving the region to bar 9 by rewriting the
            // AXHelp text the parser reads.
            fixture.builder.setAttribute(
                fixture.builder.element(3_000),
                kAXHelpAttribute as String,
                postHelp
            )
            return .success("OK")
        },
        settle: { /* skip in tests */ }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["pre_start_bar"] as? Int == 1)
    #expect(obj["post_start_bar"] as? Int == 9)
    #expect(obj["playhead_bar"] as? Int == 9)
    #expect(obj["requested"] as? Int == 9)
    #expect(obj["observed"] as? Int == 9)
}

@Test func testMoveToPlayheadReturnsStateBOnMismatch() async {
    // Pre: bar 1. Action moves region to bar 5 but playhead is at bar 9 →
    // post.startBar(5) ≠ playhead(9) → State B readback_mismatch.
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let postHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: preHelp,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: true
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in
            fixture.builder.setAttribute(
                fixture.builder.element(3_000),
                kAXHelpAttribute as String,
                postHelp
            )
            return .success("OK")
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["pre_start_bar"] as? Int == 1)
    #expect(obj["post_start_bar"] as? Int == 5)
    #expect(obj["playhead_bar"] as? Int == 9)
}

@Test func testMoveToPlayheadReturnsStateBOnNoChange() async {
    // Pre==Post → menu was a no-op. State B readback_mismatch with note.
    let staticHelp = "리전은 4 마디 에서 시작하여 6 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: staticHelp,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: true
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in .success("OK") },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["pre_start_bar"] as? Int == 4)
    #expect(obj["post_start_bar"] as? Int == 4)
    #expect(((obj["note"] as? String)?.contains("no position change"))!)
}

@Test func testMoveToPlayheadReturnsStateBWhenNoSelectedRegion() async {
    // No region has AXSelected=true → cannot snapshot pre-state →
    // State B readback_unavailable.
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: help,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: false
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in .success("OK") },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_unavailable")
}

@Test func testMoveToPlayheadReturnsStateCOnMenuError() async {
    let fixture = makeRegionFixture(
        headers: [],
        regions: [],
        playheadPosition: "1.1.1.1"
    )
    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in .success("MENU_ERROR: not found") },
        settle: { }
    )
    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "ax_write_failed")
}

// MARK: - region.select_last — State A path

@Test func testSelectLastReturnsStateAOnMatch() async {
    // Two regions; the second (bar 5) is the last. AppleScript executor
    // simulates Logic selecting it. Post-read finds AXSelected on the
    // last region → State A.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "RegionB", help: regionBHelp,
             pos: axPoint(400, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in
            // Logic flipped AXSelected=true on RegionB.
            fixture.builder.setAttribute(
                fixture.builder.element(3_001),
                kAXSelectedAttribute as String,
                true
            )
            return .success("SELECTED")
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["expected_name"] as? String == "RegionB")
    #expect(obj["selected_name"] as? String == "RegionB")
    #expect(obj["expected_start_bar"] as? Int == 5)
    #expect(obj["selected_start_bar"] as? Int == 5)
}

@Test func testSelectLastReturnsStateBOnMismatch() async {
    // AppleScript flips selection on the WRONG region (RegionA / bar 1)
    // even though "last" is RegionB / bar 5 → State B readback_mismatch.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "RegionB", help: regionBHelp,
             pos: axPoint(400, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in
            fixture.builder.setAttribute(
                fixture.builder.element(3_000),  // RegionA — the wrong one
                kAXSelectedAttribute as String,
                true
            )
            return .success("SELECTED")
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["expected_name"] as? String == "RegionB")
    #expect(obj["selected_name"] as? String == "RegionA")
}

@Test func testSelectLastReturnsStateBWhenNoSelectionPostAction() async {
    // Script returns SELECTED but never flipped AXSelected (read-back fails)
    // → State B readback_unavailable.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in .success("SELECTED") },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect(obj["expected_name"] as? String == "RegionA")
}

@Test func testSelectLastReturnsStateCWhenNoRegions() async {
    let fixture = makeRegionFixture(
        headers: [],
        regions: [],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in .success("NO_REGION") },
        settle: { }
    )

    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "element_not_found")
}

// MARK: - Helpers

@Test func testCurrentPlayheadBarParsesPositionString() {
    let fixture = makeRegionFixture(
        headers: [],
        regions: [],
        playheadPosition: "12.3.4.5"
    )
    #expect(AccessibilityChannel.currentPlayheadBar(runtime: fixture.runtime) == 12)
}

@Test func testLastRegionInfoReturnsLargestStartBar() {
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 7 마디 에서 시작하여 9 마디 에서 끝납니다., MIDI 리전."
    let regionCHelp = "리전은 4 마디 에서 시작하여 6 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "A", help: regionAHelp, pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "B", help: regionBHelp, pos: axPoint(400, 108), size: axSize(160, 24), selected: false),
            (name: "C", help: regionCHelp, pos: axPoint(250, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )
    let last = AccessibilityChannel.lastRegionInfo(runtime: fixture.runtime)
    #expect(last?.name == "B")
    #expect(last?.startBar == 7)
}

@Test func testSelectedRegionInfoReturnsRegionWithAXSelectedTrue() {
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 7 마디 에서 시작하여 9 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "A", help: regionAHelp, pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "B", help: regionBHelp, pos: axPoint(400, 108), size: axSize(160, 24), selected: true)
        ],
        playheadPosition: "1.1.1.1"
    )
    let sel = AccessibilityChannel.selectedRegionInfo(runtime: fixture.runtime)
    #expect(sel?.name == "B")
    #expect(sel?.startBar == 7)
}
