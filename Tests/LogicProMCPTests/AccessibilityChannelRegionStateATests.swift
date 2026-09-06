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
    // an accident of the fixture rather than by anything the code did.
    //
    // Injecting the clear and recording it says the operation ASKS for a clear before it writes, and
    // that is all it says: an injected seam cannot exercise the production lookup behind it. What
    // covers that is `testSelectLastPressesTheRealDeselectAllItem` below, which gives the fixture a
    // menu bar and lets the real closure run.
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

@Test func testSelectLastPressesTheRealDeselectAllItem() async {
    // The production clear, not an injected stand-in: the fixture publishes a menu bar shaped like
    // Logic's — menu-bar item, its AXMenu, the Select item, its AXMenu, the leaf carrying
    // `AXIdentifier = deselectAll:` — and the operation has to find that leaf and press it. Without
    // this, every other test here injects past the lookup, the descent bound and the AXEnabled gate.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )
    let builder = fixture.builder
    let app = builder.element(1_000)
    let menuBar = builder.element(4_000)
    let editItem = builder.element(4_001)
    let editMenu = builder.element(4_002)
    let selectItem = builder.element(4_003)
    let selectMenu = builder.element(4_004)
    let deselectAllItem = builder.element(4_005)
    let decoyItem = builder.element(4_006)

    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setAttribute(editItem, kAXTitleAttribute as String, "편집")
    builder.setChildren(menuBar, [editItem])
    builder.setChildren(editItem, [editMenu])
    builder.setAttribute(selectItem, kAXTitleAttribute as String, "선택")
    // A sibling that shares the DISPATCHER identifier Logic gives most items, so the scan has
    // something realistic to walk past.
    builder.setAttribute(decoyItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(decoyItem, kAXIdentifierAttribute as String, "localMenuItemAction:")
    builder.setChildren(editMenu, [selectItem, decoyItem])
    builder.setChildren(selectItem, [selectMenu])
    builder.setAttribute(deselectAllItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(deselectAllItem, kAXIdentifierAttribute as String, "deselectAll:")
    builder.setAttribute(deselectAllItem, kAXEnabledAttribute as String, true)
    builder.setChildren(selectMenu, [deselectAllItem])

    // Isolated first, so a failure says which piece broke rather than only that the press is missing.
    #expect(AXLogicProElements.getMenuBar(runtime: fixture.runtime) != nil, "fixture publishes a menu bar")
    #expect(AXLogicProElements.menuItem(
        identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: fixture.runtime
    ) != nil, "the identifier lookup reaches the leaf four levels down")

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        settle: { }
    )

    // `actionCalls` keys by the element's ADDRESS, not by the fixture id, so identity is compared the
    // same way the recorder computes it. Comparing against 4_005 silently never matches.
    let deselectAllKey = Int(bitPattern: Unmanaged.passUnretained(deselectAllItem).toOpaque())
    #expect(builder.actionCalls.contains {
        $0.elementID == deselectAllKey && $0.action == kAXPressAction as String
    }, "the operation must press the leaf carrying the identifier, not the decoy or its menu")
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
}

@Test func testSelectLastCertifiesAMatchingStateEvenWhenTheWriteReportedFailure() async {
    // A write that LANDS and reports that it did not. An earlier cut refused this, on the theory
    // that the write's answer said whether this call had established the selection. It does not:
    // a `true` return excludes a concurrent actor no better than a `false` one, so requiring it
    // only refused real successes — this exact shape, which is measured on this surface, where the
    // return code is uninformative in both directions.
    //
    // So the state decides, and the write's answer is reported rather than gating.
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
        selectRegion: { element, runtime in
            _ = AXHelpers.setAttribute(element, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax)
            return false            // the write lands and reports that it did not
        },
        deselectAll: { _ in true },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["reason"] == nil)
    // Reported, not gated: a caller can see that the write's answer disagreed with what happened.
    #expect(!((obj["write_reported_success"] as? Bool)!))
    #expect(obj["selected_count"] as? Int == 1)
}

@Test func testSelectLastRefusesWhenTheArrangementMovedUnderIt() async {
    // The other new conjunct. The target is chosen before the clear and two settle windows; if the
    // arrangement changes in between, the region that is last NOW is not the one this acted on.
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
    let builder = fixture.builder
    let regionA = builder.element(3_000)

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        selectRegion: { element, runtime in
            let wrote = AXHelpers.setAttribute(
                element, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax
            )
            // RegionA is dragged past RegionB while the operation is mid-flight.
            builder.setAttribute(regionA, kAXHelpAttribute as String,
                                 "리전은 9 마디 에서 시작하여 11 마디 에서 끝납니다., MIDI 리전.")
            return wrote
        },
        deselectAll: { _ in true },
        settle: { }
    )

    let obj = decodeJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(!((obj["target_is_still_last"] as? Bool)!))
}

/// Build a fixture menu bar shaped like Logic's: 편집 > its AXMenu > 선택 > its AXMenu > leaves.
/// `extraLeaves` are added beside the `deselectAll:` leaf so a test can stage a duplicate.
private func attachMenuBar(
    to builder: FakeAXRuntimeBuilder,
    app: AXUIElement,
    leafIdentifier: String = "deselectAll:",
    leafRole: String = kAXMenuItemRole as String,
    extraLeaves: [(identifier: String, role: String)] = []
) -> AXUIElement {
    let menuBar = builder.element(4_000)
    let editItem = builder.element(4_001)
    let editMenu = builder.element(4_002)
    let selectItem = builder.element(4_003)
    let selectMenu = builder.element(4_004)
    let leaf = builder.element(4_005)

    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setAttribute(editItem, kAXTitleAttribute as String, "편집")
    builder.setChildren(menuBar, [editItem])
    builder.setChildren(editItem, [editMenu])
    builder.setAttribute(selectItem, kAXTitleAttribute as String, "선택")
    builder.setChildren(editMenu, [selectItem])
    builder.setChildren(selectItem, [selectMenu])
    builder.setAttribute(leaf, kAXRoleAttribute as String, leafRole)
    builder.setAttribute(leaf, kAXIdentifierAttribute as String, leafIdentifier)
    builder.setAttribute(leaf, kAXEnabledAttribute as String, true)

    var leaves = [leaf]
    for (offset, spec) in extraLeaves.enumerated() {
        let extra = builder.element(4_100 + offset)
        builder.setAttribute(extra, kAXRoleAttribute as String, spec.role)
        builder.setAttribute(extra, kAXIdentifierAttribute as String, spec.identifier)
        builder.setAttribute(extra, kAXEnabledAttribute as String, true)
        leaves.append(extra)
    }
    builder.setChildren(selectMenu, leaves)
    return leaf
}

@Test func testMenuIdentifierLookupRefusesADuplicate() async {
    // The uniqueness half. The press test alone cannot see this: with one matching element, a
    // lookup that returns the first match without scanning behaves identically to one that scans.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_000)
    _ = attachMenuBar(to: builder, app: app,
                      extraLeaves: [(identifier: "deselectAll:", role: kAXMenuItemRole as String)])
    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.menuItem(
        identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime
    ) == nil, "two items carrying the identifier means the caller's assumption is wrong here")
}

@Test func testMenuIdentifierLookupRefusesANonMenuItemRole() async {
    // The role half, for the same reason.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_000)
    _ = attachMenuBar(to: builder, app: app, leafRole: kAXButtonRole as String)
    let runtime = builder.makeLogicRuntime(appElement: app)

    #expect(AXLogicProElements.menuItem(
        identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime
    ) == nil, "something carrying the identifier is not automatically a pressable menu item")
}

@Test func testMenuIdentifierLookupRefusesWhenAnIdentifierIsUnreadable() async {
    // The status-preserving half, which the default fixture cannot reach because it answers
    // `.success` to everything. An element whose identifier will not read could be the duplicate,
    // so the scan cannot claim uniqueness over it.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_000)
    _ = attachMenuBar(to: builder, app: app,
                      extraLeaves: [(identifier: "localMenuItemAction:", role: kAXMenuItemRole as String)])
    let opaque = builder.element(4_100)
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            guard element == opaque, attribute == (kAXIdentifierAttribute as String) else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )

    #expect(AXLogicProElements.menuItem(
        identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime
    ) == nil, "an unreadable identifier could be the duplicate; uniqueness cannot be claimed over it")
}

@Test func testMenuIdentifierLookupIgnoresAnElementItsIdentifierExcludes() async throws {
    // The other direction, which is a false REFUSAL rather than a false match. An element whose
    // identifier read succeeded and did not match is excluded by that read alone — its role being
    // unreadable cannot matter, because an excluded element is not a candidate for anything.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_000)
    let leaf = attachMenuBar(to: builder, app: app,
                             extraLeaves: [(identifier: "localMenuItemAction:", role: kAXMenuItemRole as String)])
    let excluded = builder.element(4_100)
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            guard element == excluded, attribute == (kAXRoleAttribute as String) else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )

    let found = AXLogicProElements.menuItem(
        identifier: "deselectAll:", inMenuBar: AXLocalePolicy.editMenuBar, runtime: runtime
    )
    // `?? false` would pass unconditionally when the lookup returned nil, hiding the very refusal
    // this test exists to rule out. Bind first, then assert on the bound value.
    let matched = try #require(found, "a nonmatching identifier excludes the element; its unreadable role is moot")
    #expect(CFEqual(matched, leaf), "and the match must still be the real leaf")
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

// MARK: - #774: the verifier reads the SELECTION, not the first thing in it

/// `executeScript` is `@Sendable`, so a captured `var` cannot record whether it ran. Same shape as
/// `AccessibilityRuntimeRecorder` in AccessibilityChannelTests.
private final class MoveMenuDriveRecorder: @unchecked Sendable {
    var ran = false
}

/// Logic's `Move to Playhead` acts on everything selected. `selectedRegionInfo` returns the FIRST
/// region carrying `AXSelected`, so with two selected the identity check compared one of them
/// against itself, the envelope named that one, and nothing said a second had been moved.
///
/// Verifying a multi-region move is a larger question than this readback answers — a partial
/// landing has no honest State A — so a selection that is not exactly one is refused BEFORE the
/// menu is driven. These cases pin the refusal and the single-region path it must not disturb.
@Test("a two-region selection is refused rather than verified from the first region")
func moveToPlayheadRefusesAMultiRegionSelection() async {
    let help1 = "Region starts at 1 bar  and ends at 2 bars , MIDI region."
    let help2 = "Region starts at 3 bars  and ends at 4 bars , MIDI region."
    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: help1, pos: axPoint(240, 108), size: axSize(320, 24), selected: true),
            (name: "RegionB", help: help2, pos: axPoint(600, 108), size: axSize(320, 24), selected: true),
        ],
        playheadPosition: "9.1.1.1"
    )

    let menu = MoveMenuDriveRecorder()
    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in menu.ran = true; return .success("OK") },
        settle: { }
    )

    let obj = decodeJSON(result.message)
    #expect(obj["state"] as? String == "B")
    #expect(obj["verified"] as? Bool != true)
    #expect(obj["selected_count"] as? Int == 2)
    #expect((obj["selected_names"] as? [String])?.sorted() == ["RegionA", "RegionB"])
    // Refused BEFORE the menu is driven: the operation must not move what it cannot certify.
    #expect(menu.ran == false, "the menu was driven for a selection this readback cannot verify")
}

/// The single-region path must be untouched by that refusal — otherwise the fix would trade one
/// blind spot for a regression, and the State A case is the one every caller depends on.
@Test("a one-region selection still reaches State A")
func moveToPlayheadStillVerifiesASingleRegion() async {
    let preHelp = "Region starts at 1 bar  and ends at 2 bars , MIDI region."
    let postHelp = "Region starts at 9 bars  and ends at 10 bars , MIDI region."
    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(name: "RegionA", help: preHelp, pos: axPoint(240, 108), size: axSize(320, 24), selected: true)],
        playheadPosition: "9.1.1.1"
    )

    let menu = MoveMenuDriveRecorder()
    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in
            menu.ran = true
            fixture.builder.setAttribute(
                fixture.builder.element(3_000), kAXHelpAttribute as String, postHelp
            )
            return .success("OK")
        },
        settle: { }
    )

    let obj = decodeJSON(result.message)
    #expect(obj["state"] as? String == "A")
    #expect(obj["verified"] as? Bool == true)
    #expect(obj["selected_count"] == nil, "the refusal's fields must not leak into the verified path")
    // This is what makes the `menu.ran == false` assertion in the refusal case mean something: the
    // same recorder, same fixture shape, DOES observe the drive when the operation proceeds.
    // Without it that negative could pass because nothing ever drives the menu in these tests.
    #expect(menu.ran == true, "the recorder cannot see the drive, so its negative proves nothing")
}
