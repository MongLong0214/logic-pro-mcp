@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #543: `mixer.set_volume` / `mixer.set_pan` used to refuse with only
// "Cannot locate <label> control for track <n>" — one message for three
// distinguishable failures (no track-header rail at all, an out-of-range
// index, or a header with no slider). The fix names WHICH step failed in a
// `control_lookup` object so a reporter who cannot reproduce the bug locally
// can still tell the maintainer which of the three broke. These tests drive
// `AccessibilityChannel.defaultSetMixerValue` directly against a fake AX
// runtime (the same `FakeAXRuntimeBuilder` seam `AccessibilityChannelTests`
// uses) so each of the three lookup steps is provably exercised.

/// Decodes a State-C JSON receipt into a plain dictionary for field assertions.
private func decodeIssue543JSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

/// A bare app+window with no track-header rail anywhere in the tree: the
/// container lookup (`getTrackHeaders`) fails outright.
private func makeNoTrackHeaderRailRuntime() -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_000)
    let window = builder.element(543_001)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    // Deliberately no children on `window` — no list/scroll-area/group/outline
    // candidate exists for `getTrackHeaders` to find.
    return builder.makeLogicRuntime(appElement: app)
}

/// One track-header row (Logic-12-style `AXList id="Track Headers"` rail)
/// carrying both a volume fader and a pan slider, so index 0 resolves a
/// working control. `trackTitle`, when supplied, is set as the header's
/// `AXTitle` — a distinctive value used only to prove it never leaks into
/// the failure receipt of an unrelated index.
@discardableResult
private func attachOneWorkingTrackHeader(
    _ builder: FakeAXRuntimeBuilder,
    window: AXUIElement,
    baseID: Int,
    trackTitle: String? = nil
) -> (rail: AXUIElement, header: AXUIElement) {
    let rail = builder.element(baseID)
    builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
    let header = builder.element(baseID + 1)
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    if let trackTitle {
        builder.setAttribute(header, kAXTitleAttribute as String, trackTitle)
    }
    let volumeSlider = builder.element(baseID + 2)
    builder.setAttribute(volumeSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(volumeSlider, kAXDescriptionAttribute as String, "Volume")
    builder.setAttribute(volumeSlider, kAXValueAttribute as String, 100.0)
    builder.setAttribute(volumeSlider, kAXMinValueAttribute as String, 0.0)
    builder.setAttribute(volumeSlider, kAXMaxValueAttribute as String, 200.0)
    let panSlider = builder.element(baseID + 3)
    builder.setAttribute(panSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(panSlider, kAXDescriptionAttribute as String, "")
    builder.setAttribute(panSlider, kAXValueAttribute as String, 64.0)
    builder.setAttribute(panSlider, kAXMinValueAttribute as String, 0.0)
    builder.setAttribute(panSlider, kAXMaxValueAttribute as String, 127.0)
    builder.setChildren(header, [volumeSlider, panSlider])
    builder.setChildren(rail, [header])
    builder.setChildren(window, [rail])
    return (rail, header)
}

/// One track-header row with the rail correctly resolved, but the header
/// itself has NO `AXSlider` descendants at all (its only child is an
/// unrelated static-text row) — exercises the depth-4-slider-search miss.
/// `trackTitle`, when supplied, is set as the header's `AXTitle`.
@discardableResult
private func attachOneSliderlessTrackHeader(
    _ builder: FakeAXRuntimeBuilder,
    window: AXUIElement,
    baseID: Int,
    trackTitle: String? = nil
) -> (rail: AXUIElement, header: AXUIElement) {
    let rail = builder.element(baseID)
    builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
    let header = builder.element(baseID + 1)
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    if let trackTitle {
        builder.setAttribute(header, kAXTitleAttribute as String, trackTitle)
    }
    let nameField = builder.element(baseID + 2)
    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(nameField, kAXValueAttribute as String, trackTitle ?? "Untitled")
    builder.setChildren(header, [nameField])
    builder.setChildren(rail, [header])
    builder.setChildren(window, [rail])
    return (rail, header)
}

// MARK: - 1. No track headers at all

@Test func testIssue543MissingRailReportsTrackHeaderListNotFound() throws {
    let runtime = makeNoTrackHeaderRailRuntime()
    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "0", "value": "0.5"], target: .volume, runtime: runtime
    )
    #expect(!result.isSuccess)
    let body = decodeIssue543JSON(result.message)
    #expect(try #require(body["error"] as? String) == "element_not_found")
    let lookup = try #require(body["control_lookup"] as? [String: Any])
    #expect(try #require(lookup["failed_step"] as? String) == "track_header_list_not_found")
    // No rail was read, so there is no count to report. Publishing `header_count: 0` here
    // would assert "this project has zero tracks" from a read that never happened.
    #expect(lookup["header_count"] == nil)
    #expect(try #require(lookup["requested_index"] as? Int) == 0)
    // No header was found, so there is nothing to have counted sliders in.
    #expect(lookup["sliders_in_header"] == nil)
}

// MARK: - 2. Headers exist, requested index out of range

@Test func testIssue543OutOfRangeIndexReportsNoHeaderAtIndexWithRealCount() throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_100)
    let window = builder.element(543_101)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    attachOneWorkingTrackHeader(builder, window: window, baseID: 543_110)
    let runtime = builder.makeLogicRuntime(appElement: app)

    // Only one header exists (index 0); ask for index 5.
    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "5", "value": "0.5"], target: .volume, runtime: runtime
    )
    #expect(!result.isSuccess)
    let body = decodeIssue543JSON(result.message)
    #expect(try #require(body["error"] as? String) == "element_not_found")
    let lookup = try #require(body["control_lookup"] as? [String: Any])
    #expect(try #require(lookup["failed_step"] as? String) == "no_header_at_index")
    #expect(try #require(lookup["header_count"] as? Int) == 1)
    #expect(try #require(lookup["requested_index"] as? Int) == 5)
    #expect(lookup["sliders_in_header"] == nil)
}

// MARK: - 3. Header found, no slider within depth 4

@Test func testIssue543SliderlessHeaderReportsHeaderHasNoSliderWithinDepth4() throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_200)
    let window = builder.element(543_201)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    attachOneSliderlessTrackHeader(builder, window: window, baseID: 543_210)
    let runtime = builder.makeLogicRuntime(appElement: app)

    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "0", "value": "0.5"], target: .volume, runtime: runtime
    )
    #expect(!result.isSuccess)
    let body = decodeIssue543JSON(result.message)
    #expect(try #require(body["error"] as? String) == "element_not_found")
    let lookup = try #require(body["control_lookup"] as? [String: Any])
    #expect(try #require(lookup["failed_step"] as? String) == "header_has_no_slider_within_depth_4")
    #expect(try #require(lookup["header_count"] as? Int) == 1)
    #expect(try #require(lookup["requested_index"] as? Int) == 0)
    #expect(try #require(lookup["sliders_in_header"] as? Int) == 0)
}

// MARK: - 4. The pre-existing State-C contract is unchanged (additive only)

@Test func testIssue543ControlLookupIsAdditiveToPreexistingStateCContract() throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_300)
    let window = builder.element(543_301)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    attachOneWorkingTrackHeader(builder, window: window, baseID: 543_310)
    let runtime = builder.makeLogicRuntime(appElement: app)

    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "9", "value": "0.5"], target: .pan, runtime: runtime
    )
    #expect(!result.isSuccess)
    let body = decodeIssue543JSON(result.message)

    // Pre-existing fields (#543 is additive — none of these may move).
    #expect(try #require(body["error"] as? String) == "element_not_found")
    #expect(try #require(body["state"] as? String) == "C")
    #expect(try #require(body["operation"] as? String) == "mixer.set_pan")
    #expect(try #require(body["track"] as? Int) == 9)
    #expect(try #require(body["requested"] as? Double) == 0.5)
    let targetIdentity = try #require(body["target_identity"] as? [String: Any])
    #expect(try #require(targetIdentity["track_index"] as? Int) == 9)
    #expect(try #require(targetIdentity["control"] as? String) == "pan")
    let recoveryHint = try #require(body["recovery_hint"] as? String)
    #expect(recoveryHint.contains("9"))

    // New field is present alongside, not instead of, the above.
    let lookup = try #require(body["control_lookup"] as? [String: Any])
    #expect(try #require(lookup["failed_step"] as? String) == "no_header_at_index")
}

// MARK: - 5. No user content — diagnostics are structural only

@Test func testIssue543DiagnosticsCarryNoTrackNameContent() throws {
    let sentinel = "SENTINEL_TRACK_NAME_9f3c2b_DO_NOT_LEAK"
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_400)
    let window = builder.element(543_401)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    // The header the code actually resolves (index 0) carries the sentinel as
    // its title AND as a child static-text value — the two most likely spots
    // a careless diagnostic addition would read a "name" from.
    attachOneSliderlessTrackHeader(builder, window: window, baseID: 543_410, trackTitle: sentinel)
    let runtime = builder.makeLogicRuntime(appElement: app)

    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "0", "value": "0.5"], target: .volume, runtime: runtime
    )
    #expect(!result.isSuccess)
    // Sanity: this fixture does reach the header (not the empty-rail or
    // out-of-range branch) — otherwise the sentinel's absence would be vacuous.
    let body = decodeIssue543JSON(result.message)
    let lookup = try #require(body["control_lookup"] as? [String: Any])
    #expect(try #require(lookup["failed_step"] as? String) == "header_has_no_slider_within_depth_4")
    #expect(!result.message.contains(sentinel))
}

// MARK: - 6. The rail was found but could not be enumerated

/// A correctly identified `Track Headers` rail whose children read FAILS. The
/// old code called `allTrackHeaders`, which flattens this into `[]`, and then
/// reported `track_header_list_not_found` with `header_count: 0` — sending the
/// reader to look for a Tracks area that is on screen and populated.
@Test func testIssue543UnreadableRailIsNotReportedAsMissingOrEmpty() throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_500)
    let window = builder.element(543_501)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    let (rail, _) = attachOneWorkingTrackHeader(builder, window: window, baseID: 543_510)
    let railID = builder.elementID(rail)
    // Fail the children read for the rail ONLY, so the rail is still discovered as a
    // candidate and the failure lands in enumeration, where it belongs. BOTH readers must
    // fail: a real `kAXErrorCannotComplete` from the window server is seen as an empty
    // array by the legacy `children` accessor and as `.failure` by the status-preserving
    // one. Failing only the latter left the actual fader lookup succeeding, so the
    // diagnostic branch was never entered and this test passed on the wrong path.
    let isRail: @Sendable (AXUIElement) -> Bool = { element in
        Int(bitPattern: Unmanaged.passUnretained(element).toOpaque()) == railID
    }
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        childrenHandler: { isRail($0) ? [] : nil },
        childrenResultHandler: {
            isRail($0) ? .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) : nil
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )

    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "0", "value": "0.5"], target: .volume, runtime: runtime
    )
    #expect(!result.isSuccess)
    let lookup = try #require(decodeIssue543JSON(result.message)["control_lookup"] as? [String: Any])
    #expect(try #require(lookup["failed_step"] as? String) == "track_header_list_unreadable")
    // The two claims this receipt must never make about an unreadable rail.
    #expect(lookup["header_count"] == nil)
    #expect(try #require(lookup["failed_step"] as? String) != "track_header_list_not_found")
}

/// Control for the test above: the SAME fixture without the induced failure
/// must resolve the header. Without this, `track_header_list_unreadable` could
/// be produced by a fixture that never built a rail at all, and the test would
/// pass for a reason unrelated to the mutation it claims to detect.
@Test func testIssue543UnreadableRailControlResolvesWhenChildrenReadSucceeds() throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_600)
    let window = builder.element(543_601)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    attachOneWorkingTrackHeader(builder, window: window, baseID: 543_610)
    let runtime = builder.makeLogicRuntime(appElement: app)

    // Index 0 resolves a real slider here, so the op gets past the lookup guard
    // entirely — proving the fixture's rail is well-formed and readable.
    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "0", "value": "0.5"], target: .volume, runtime: runtime
    )
    let body = decodeIssue543JSON(result.message)
    #expect(body["control_lookup"] == nil)
}

// MARK: - 7. The rail was read and is genuinely empty

/// A readable `Track Headers` rail with no rows. This IS the case where zero is
/// evidence, and it must be distinguishable from both of the above.
@Test func testIssue543EmptyButReadableRailReportsEmptyWithACount() throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(543_700)
    let window = builder.element(543_701)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    let rail = builder.element(543_710)
    builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(rail, [])
    builder.setChildren(window, [rail])
    let runtime = builder.makeLogicRuntime(appElement: app)

    let result = AccessibilityChannel.defaultSetMixerValue(
        params: ["index": "0", "value": "0.5"], target: .volume, runtime: runtime
    )
    #expect(!result.isSuccess)
    let lookup = try #require(decodeIssue543JSON(result.message)["control_lookup"] as? [String: Any])
    #expect(try #require(lookup["failed_step"] as? String) == "track_header_list_empty")
    // Here the read succeeded, so the count is an observation and may be stated.
    #expect(try #require(lookup["header_count"] as? Int) == 0)
}
