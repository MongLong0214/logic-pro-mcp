import Foundation
import Testing
@testable import LogicProMCP

// v3.1.5 — Issues #3 / #4 / #5 fixes route AppleScript output through
// `markersViaAppleScript` / `projectInfoViaAppleScript` /
// `tracksViaAppleScript`. These helpers accept an injectable
// `executeScript` closure so we drive the parser against frozen output
// without a live Logic install. Field separator (US, U+001F) and record
// separator (RS, U+001E) match the Swift constants used by the production
// AppleScript bodies. We construct them via UnicodeScalar to avoid
// embedding raw control bytes in this source file (Swift compiler rejects
// unprintable ASCII outside of escape sequences).

private let FS = String(UnicodeScalar(0x1F)!)
private let RS = String(UnicodeScalar(0x1E)!)

private func wrapAppleScriptResult(_ raw: String) -> ChannelResult {
    // Mirror production AppleScriptChannel.escapeJSON so the test wrapper
    // produces wire-identical JSON to the live path.
    return .success("{\"result\":\"\(AppleScriptChannel.escapeJSON(raw))\"}")
}

private func decodeJSONArray(_ s: String) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [[String: Any]] ?? []
}

private func decodeJSONObject(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

// MARK: - Markers (Issue #5)

@Test
func markersAppleScriptParsesNamesAndPositions() async {
    let payload = "Intro\(FS)1\(RS)Verse\(FS)17\(RS)Chorus\(FS)33\(RS)"
    let result = await AccessibilityChannel.markersViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected non-nil success result")
        return
    }
    let arr = decodeJSONArray(json)
    #expect(arr.count == 3)
    #expect(arr[0]["name"] as? String == "Intro")
    #expect(arr[1]["name"] as? String == "Verse")
    #expect(arr[2]["name"] as? String == "Chorus")
    #expect(arr[0]["position"] as? String == "1.1.1.1")
    #expect(arr[1]["position"] as? String == "5.1.1.1") // beat 17 -> bar 5 in 4/4
    #expect(arr[2]["position"] as? String == "9.1.1.1")
}

@Test
func markersAppleScriptReturnsNilForEmptyPayload() async {
    let result = await AccessibilityChannel.markersViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult("") }
    )
    #expect(result == nil)
}

@Test
func markersAppleScriptReturnsNilForFailure() async {
    let result = await AccessibilityChannel.markersViaAppleScript(
        executeScript: { _ in .error("AppleScript error: TCC denied") }
    )
    #expect(result == nil)
}

@Test
func markersAppleScriptSkipsEmptyNames() async {
    let payload = "\(FS)1\(RS)Real Marker\(FS)5\(RS)"
    let result = await AccessibilityChannel.markersViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let arr = decodeJSONArray(json)
    #expect(arr.count == 1)
    #expect(arr[0]["name"] as? String == "Real Marker")
}

@Test
func markersAppleScriptHandlesUnparseablePositionWithIndexFallback() async {
    let payload = "Intro\(FS)not-a-number\(RS)"
    let result = await AccessibilityChannel.markersViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let arr = decodeJSONArray(json)
    #expect(arr.count == 1)
    #expect(arr[0]["position"] as? String == "1.1.1.1")
}

@Test
func formatBeatsAsBarPositionRoundsCorrectly() {
    #expect(AccessibilityChannel.formatBeatsAsBarPosition("1") == "1.1.1.1")
    #expect(AccessibilityChannel.formatBeatsAsBarPosition("5") == "2.1.1.1")
    #expect(AccessibilityChannel.formatBeatsAsBarPosition("3") == "1.3.1.1")
    #expect(AccessibilityChannel.formatBeatsAsBarPosition("17") == "5.1.1.1")
    #expect(AccessibilityChannel.formatBeatsAsBarPosition("") == nil)
    #expect(AccessibilityChannel.formatBeatsAsBarPosition("-1") == nil)
    #expect(AccessibilityChannel.formatBeatsAsBarPosition("abc") == nil)
}

// MARK: - ProjectInfo (Issue #4)

@Test
func projectInfoAppleScriptParsesAllFields() async {
    let payload = "tktd_SoulCrevasse\(FS)122.0\(FS)4/4\(FS)12"
    let result = await AccessibilityChannel.projectInfoViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let obj = decodeJSONObject(json)
    #expect(obj["name"] as? String == "tktd_SoulCrevasse")
    #expect((obj["tempo"] as? Double) == 122.0)
    #expect(obj["timeSignature"] as? String == "4/4")
    #expect(obj["trackCount"] as? Int == 12)
}

@Test
func projectInfoAppleScriptFallsBackToCachedTempo() async {
    let payload = "Project\(FS)\(FS)4/4\(FS)8" // empty tempo field
    let result = await AccessibilityChannel.projectInfoViaAppleScript(
        cachedTransportTempo: 87.5,
        cachedTrackCount: 0,
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let obj = decodeJSONObject(json)
    #expect((obj["tempo"] as? Double) == 87.5)
}

@Test
func projectInfoAppleScriptFallsBackToCachedTrackCount() async {
    let payload = "Project\(FS)100\(FS)3/4\(FS)abc" // invalid track count
    let result = await AccessibilityChannel.projectInfoViaAppleScript(
        cachedTransportTempo: nil,
        cachedTrackCount: 7,
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let obj = decodeJSONObject(json)
    #expect(obj["trackCount"] as? Int == 7)
}

@Test
func projectInfoAppleScriptReturnsNilForEmptyPayload() async {
    let result = await AccessibilityChannel.projectInfoViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult("") }
    )
    #expect(result == nil)
}

@Test
func projectInfoAppleScriptReturnsNilForInsufficientFields() async {
    let payload = "name only" // no separators -> 1 field
    let result = await AccessibilityChannel.projectInfoViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    #expect(result == nil)
}

@Test
func projectInfoAppleScriptDefaultsTempoWhenAllSourcesMissing() async {
    let payload = "Project\(FS)\(FS)\(FS)0"
    let result = await AccessibilityChannel.projectInfoViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let obj = decodeJSONObject(json)
    // ProjectInfo struct default tempo is 120
    #expect((obj["tempo"] as? Double) == 120.0)
}

// MARK: - Tracks (Issue #3)

@Test
func tracksAppleScriptParsesProjectTracks() async {
    let payload =
        "Kick\(FS)false\(FS)false\(FS)false\(FS)true\(RS)" +
        "Snare\(FS)true\(FS)false\(FS)false\(FS)false\(RS)" +
        "Bass\(FS)false\(FS)true\(FS)true\(FS)false\(RS)"
    let result = await AccessibilityChannel.tracksViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let arr = decodeJSONArray(json)
    #expect(arr.count == 3)
    #expect(arr[0]["name"] as? String == "Kick")
    #expect(arr[0]["isMuted"] as? Bool == false)
    #expect(arr[0]["isSelected"] as? Bool == true)
    #expect(arr[1]["name"] as? String == "Snare")
    #expect(arr[1]["isMuted"] as? Bool == true)
    #expect(arr[2]["name"] as? String == "Bass")
    #expect(arr[2]["isSoloed"] as? Bool == true)
    #expect(arr[2]["isArmed"] as? Bool == true)
}

@Test
func tracksAppleScriptReturnsNilForEmptyPayload() async {
    let result = await AccessibilityChannel.tracksViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult("") }
    )
    #expect(result == nil)
}

@Test
func tracksAppleScriptSkipsEmptyNames() async {
    let payload = "\(FS)false\(FS)false\(FS)false\(FS)false\(RS)Real\(FS)false\(FS)false\(FS)false\(FS)false\(RS)"
    let result = await AccessibilityChannel.tracksViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let arr = decodeJSONArray(json)
    #expect(arr.count == 1)
    #expect(arr[0]["name"] as? String == "Real")
}

@Test
func tracksAppleScriptDefaultsBoolFieldsToFalse() async {
    let payload = "OnlyName\(RS)"
    let result = await AccessibilityChannel.tracksViaAppleScript(
        executeScript: { _ in wrapAppleScriptResult(payload) }
    )
    guard case .success(let json) = result else {
        Issue.record("expected success")
        return
    }
    let arr = decodeJSONArray(json)
    #expect(arr.count == 1)
    #expect(arr[0]["isMuted"] as? Bool == false)
    #expect(arr[0]["isSoloed"] as? Bool == false)
    #expect(arr[0]["isArmed"] as? Bool == false)
    #expect(arr[0]["isSelected"] as? Bool == false)
}

// MARK: - parseAppleScriptResult helper

@Test
func parseAppleScriptResultDecodesWrappedPayload() {
    // RFC 8259 forbids raw control bytes inside a JSON string, so the
    // production wrapper escapes U+001F as ``. After parse we get
    // the raw delimiter back in the result value.
    let wrapped = "{\"result\":\"hello\\u001Fworld\"}"
    #expect(AccessibilityChannel.parseAppleScriptResult(wrapped) == "hello\(FS)world")
}

@Test
func parseAppleScriptResultDecodesPlainAscii() {
    let wrapped = "{\"result\":\"plain text\"}"
    #expect(AccessibilityChannel.parseAppleScriptResult(wrapped) == "plain text")
}

@Test
func parseAppleScriptResultReturnsNilForInvalidJSON() {
    #expect(AccessibilityChannel.parseAppleScriptResult("not json") == nil)
}

@Test
func parseAppleScriptResultReturnsNilForMissingResultKey() {
    #expect(AccessibilityChannel.parseAppleScriptResult("{\"other\":\"v\"}") == nil)
}

// MARK: - Production default executeScript path coverage
//
// `markersViaAppleScript` / `projectInfoViaAppleScript` /
// `tracksViaAppleScript` accept an injectable executeScript closure but
// also carry a production default that calls `AppleScriptChannel.executeAppleScript`
// directly. The CI runner has no Logic Pro installed, so these calls
// return `.error` from osascript ("application 'Logic Pro' isn't running"
// or equivalent), which the helpers translate to `nil`. Invoking the
// default-path overloads here exercises the production wiring lines that
// inject-only callers don't reach.

@Test
func markersViaAppleScriptDefaultExecuteIsReachable() async {
    // Default executeScript closure → AppleScriptChannel.executeAppleScript
    // → osascript without Logic available returns error → helper returns nil.
    // We don't assert on result polarity (could be nil on CI / non-nil on
    // dev machines with Logic running); the goal is line coverage of the
    // default branch.
    let result = await AccessibilityChannel.markersViaAppleScript()
    _ = result
}

@Test
func projectInfoViaAppleScriptDefaultExecuteIsReachable() async {
    let result = await AccessibilityChannel.projectInfoViaAppleScript(
        cachedTransportTempo: 100,
        cachedTrackCount: 1
    )
    _ = result
}

@Test
func tracksViaAppleScriptDefaultExecuteIsReachable() async {
    let result = await AccessibilityChannel.tracksViaAppleScript()
    _ = result
}

// MARK: - axBacked Runtime production wiring coverage

@Test
func axBackedRuntimeWiresAppleScriptHelpers() async {
    // Construct the production-wired Runtime and invoke the new closures.
    // Each closure forwards to the production default helper above.
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isLogicProRunning: { false }  // Skip live AX paths
    )
    _ = await runtime.markersAppleScript()
    _ = await runtime.projectInfoAppleScript(120.0, 0)
    _ = await runtime.tracksAppleScript()
}

// MARK: - Default closure defaults in custom Runtime construction

@Test
func customRuntimeWithoutAppleScriptHelpersReturnsNilFromDefaultClosures() async {
    // Tests that build a Runtime by hand without supplying the new
    // closures get nil-returning defaults — preserves pre-v3.1.5 behaviour
    // for ~800 existing tests with stubbed AX channels. This test pins
    // that contract so a future refactor doesn't accidentally regress it.
    let runtime = AccessibilityChannel.Runtime(
        isTrusted: { true },
        isLogicProRunning: { true },
        appRoot: { nil },
        transportState: { .success("{}") },
        toggleTransportButton: { _ in .success("") },
        setTempo: { _ in .success("") },
        setCycleRange: { _ in .success("") },
        tracks: { .success("[]") },
        selectedTrack: { .success("null") },
        selectTrack: { _ in .success("") },
        setTrackToggle: { _, _ in .success("") },
        renameTrack: { _ in .success("") },
        mixerState: { .success("[]") },
        channelStrip: { _ in .success("null") },
        setMixerValue: { _, _ in .success("") },
        projectInfo: { .success("{}") }
    )
    #expect(await runtime.markersAppleScript() == nil)
    #expect(await runtime.projectInfoAppleScript(nil, 0) == nil)
    #expect(await runtime.tracksAppleScript() == nil)
}
