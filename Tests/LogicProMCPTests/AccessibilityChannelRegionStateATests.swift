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
/// A @Sendable call counter, so a test can require that an injected step ran — or did not.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = 0
    func fire() { lock.lock(); fired += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return fired }
}

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

/// The pre- and post-reads both ask for "the selected region". Nothing in Logic guarantees that is
/// the SAME region across the menu click, and `startBar` cannot be the identity that decides it —
/// it is the property this operation exists to change.
///
/// Without a same-region gate, a selection that drifted mid-click certifies State A on a region the
/// caller never asked about, purely because it happens to sit on the playhead. That is a false
/// State A: performed, and "verified" against the wrong subject.
@Test func testMoveToPlayheadRefusesStateAWhenTheSelectionDrifted() async {
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    // Already sitting on the playhead, on a different track. If the gate only compared startBar to
    // the playhead, this region would satisfy it.
    let regionBHelp = "리전은 9 마디 에서 시작하여 11 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40)), (axPoint(0, 200), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp, pos: axPoint(240, 108),
             size: axSize(320, 24), selected: true),
            (name: "RegionB", help: regionBHelp, pos: axPoint(900, 208),
             size: axSize(320, 24), selected: false),
        ],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in
            // Logic's selection moves to RegionB during the click. RegionA never moves.
            fixture.builder.setAttribute(
                fixture.builder.element(3_000), kAXSelectedAttribute as String, false
            )
            fixture.builder.setAttribute(
                fixture.builder.element(3_001), kAXSelectedAttribute as String, true
            )
            return .success("OK")
        },
        settle: { /* skip in tests */ }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    let verified = obj["verified"] as? Bool ?? true
    #expect(!verified)
    #expect(obj["state"] as? String == "B")
    #expect(obj["reason"] as? String == "readback_mismatch")
    // The envelope has to say WHICH region it ended up looking at, or the caller cannot tell this
    // from a region that simply failed to move.
    #expect(obj["region_name"] as? String == "RegionA")
    #expect(obj["post_region_name"] as? String == "RegionB")
}

/// A region the enumeration could not place against any track header reports `trackIndex == -1`.
/// That is a readback gap, and a gap is not a match — pairing it with an equal name would let two
/// different unplaced regions certify each other.
@Test func testMoveToPlayheadRefusesStateAWhenTheTrackCannotBePlaced() async {
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let postHelp = "리전은 9 마디 에서 시작하여 11 마디 에서 끝납니다., MIDI 리전."

    // No track headers at all, so every region's trackIndex resolves to -1.
    let fixture = makeRegionFixture(
        headers: [],
        regions: [(
            name: "RegionA", help: preHelp, pos: axPoint(240, 108),
            size: axSize(320, 24), selected: true
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in
            fixture.builder.setAttribute(
                fixture.builder.element(3_000), kAXHelpAttribute as String, postHelp
            )
            return .success("OK")
        },
        settle: { /* skip in tests */ }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    let verified = obj["verified"] as? Bool ?? true
    #expect(!verified)
    #expect(obj["pre_track_index"] as? Int == -1)
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
    // Two regions; the second (bar 5) is the last. There is no AppleScript executor in this call
    // any more — #767 replaced the script with a Swift AX write, and the fake runtime's setter is
    // what makes the target read back as selected. Post-read finds exactly that one region
    // selected → State A.
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

@Test func testSelectLastFailsClosedWhenAXSelectedWriteFails() async {
    // Order-7 coordinate-free campaign: the former `click at {center}` fallback
    // after a failed AXSelected write was REMOVED. A SELECT_FAILED marker from
    // the script must fail closed (State C ax_write_failed) with no fallback —
    // never a fabricated success.
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
        selectRegion: { _, _ in false },
        settle: { }
    )

    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    let success = (obj["success"] as? Bool)!
    #expect(!success)
    #expect(obj["error"] as? String == "ax_write_failed")
    let hint = obj["hint"] as? String ?? ""
    #expect(hint.contains("no fallback"))
}

@Test func testSelectLastReturnsStateBOnMismatch() async {
    // The injected write lands on the WRONG region (RegionA / bar 1) even though "last" is
    // RegionB / bar 5 → State B readback_mismatch. Injected rather than scripted: the production
    // path writes AXSelected directly, so a wrong-target case has to be staged at that seam.
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
        selectRegion: { _, _ in
            // #767 — the seam is the SELECTION now, not a script. Logic lands on the wrong
            // region: the write goes to RegionA while the last region is RegionB, which is
            // exactly the state the readback exists to notice.
            fixture.builder.setAttribute(
                fixture.builder.element(3_000),
                kAXSelectedAttribute as String,
                true
            )
            return true
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

@Test func testSelectLastReturnsStateBWhenNothingIsSelectedAfterTheWrite() async {
    // The write reports success and the selection is empty afterwards.
    //
    // This asserted `readback_unavailable` until #767, which was the old singular readback's
    // conflation showing through: it answered `nil` both when the tree could not be enumerated and
    // when it enumerated fine and nothing was selected. Those are different facts and only one of
    // them is a readback failure. The set-valued readback separates them, so this is a MISMATCH —
    // one region expected, zero observed — and the envelope carries the count that says so.
    // `readback_unavailable` still means what it says: the tree stopped being enumerable
    // mid-operation, which this fixture cannot stage because a runtime that fails enumeration fails
    // it for the target lookup too and returns State C first.
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
        selectRegion: { _, _ in
            // The write reports success and nothing is selected afterwards — AX return codes
            // lie, so the readback is the verdict and this is the case that proves it.
            true
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["selected_count"] as? Int == 0)
    #expect(obj["expected_name"] as? String == "RegionA")
}

@Test func testSelectLastNarrowsItsScopeWhenARegionIsOutsideTheViewport() async {
    // The control for the `scope` field: it has to be able to say the narrower thing, or it is a
    // constant wearing a flag's clothes. A region parked far to the right of the window is dropped
    // by the enumeration, which makes "last" the region that remains — a true answer about a
    // smaller question, and the envelope has to be the thing that says which question it answered.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 90 마디 에서 시작하여 92 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "RegionB", help: regionBHelp,
             pos: axPoint(5_000, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )
    // The fixture leaves the window frameless, which makes every item count as visible. Give it
    // one so the viewport test has something to reject against.
    let window = fixture.builder.element(1_001)
    fixture.builder.setAttribute(window, kAXPositionAttribute as String, axPoint(0, 0))
    fixture.builder.setAttribute(window, kAXSizeAttribute as String, axSize(600, 400))

    // The fixture has no menu bar, so the production Deselect All lookup can only return nil. Left
    // alone, this test would pass with the identifier lookup, the descent bound, the AXEnabled gate
    // and the press ALL broken — the regions start unselected, so the pre-state gate is satisfied by
    // an accident of the fixture rather than by anything the code did. Injecting the clear and
    // recording it is what makes the test about the composition.
    let cleared = Recorder()
    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        deselectAll: { _ in cleared.fire(); return true },
        settle: { }
    )

    #expect(cleared.count == 1, "the operation must clear the selection before it writes")
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["scope"] as? String == "visible_arrange_area")
    #expect(obj["scope_reason"] as? String == "logic_ax_viewport_only")
    // RegionB is off-viewport and therefore not a candidate; the last VISIBLE region is RegionA.
    #expect(obj["selected_name"] as? String == "RegionA")
    #expect(obj["selected_count"] as? Int == 1)
}

@Test func testSelectLastReportsWholeArrangementWhenNothingIsDropped() async {
    // The other side of the same control, so a failure tells them apart.
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
    let window = fixture.builder.element(1_001)
    fixture.builder.setAttribute(window, kAXPositionAttribute as String, axPoint(0, 0))
    fixture.builder.setAttribute(window, kAXSizeAttribute as String, axSize(600, 400))

    let cleared = Recorder()
    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        deselectAll: { _ in cleared.fire(); return true },
        settle: { }
    )

    #expect(cleared.count == 1, "the operation must clear the selection before it writes")
    let obj = decodeJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["scope"] as? String == "whole_arrangement")
    #expect(obj["scope_reason"] == nil)
    #expect(obj["selected_name"] as? String == "RegionB")
}

@Test func testSelectLastRefusesWhenDeselectAllDidNotEmptyTheSelection() async {
    // The pre-state gate. `AXSelected = true` is a TOGGLE (measured 2026-09-04: three writes of
    // `true` to one region from an empty selection give on, OFF, on), so a write onto a selection
    // that is not empty cannot be shown to have ESTABLISHED the resulting selection — it may have
    // turned the target off, or the target may simply have been selected already.
    // Deselect All reporting success is not evidence that it emptied anything; the readback is.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: true),
            (name: "RegionB", help: regionBHelp,
             pos: axPoint(400, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    // The envelope refusing is half of it. An implementation that wrote FIRST and then produced the
    // same refusal would satisfy every assertion about the envelope while having toggled a region,
    // so the write is recorded and required not to have happened.
    let wrote = Recorder()
    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        selectRegion: { _, _ in wrote.fire(); return true },
        deselectAll: { _ in true },   // reports success, clears nothing
        settle: { }
    )

    #expect(wrote.count == 0, "a refused pre-state must not be written through")
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "noop_unobservable")
    #expect(obj["selected_before_count"] as? Int == 1)
}

@Test func testSelectLastRefusesWhenTheWriteLeavesMoreThanOneRegionSelected() async {
    // The post-state gate, and the reason it is set-valued. The toggle can land the target and
    // leave something else selected; asking only "is the target selected?" answers yes, and the
    // operations that consume a selection then act on both regions. State A is the selection BEING
    // the target, not containing it.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: true),
            (name: "RegionB", help: regionBHelp,
             pos: axPoint(400, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )
    let regionA = fixture.builder.element(3_000)
    let builder = fixture.builder

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        selectRegion: { element, runtime in
            // The target lands, and RegionA comes back with it.
            let wrote = AXHelpers.setAttribute(
                element, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax
            )
            builder.setAttribute(regionA, kAXSelectedAttribute as String, true)
            return wrote
        },
        deselectAll: { _ in
            builder.setAttribute(regionA, kAXSelectedAttribute as String, false)
            return true
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["selected_count"] as? Int == 2)
}

@Test func testSelectLastReturnsStateCWhenNoRegions() async {
    let fixture = makeRegionFixture(
        headers: [],
        regions: [],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
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
