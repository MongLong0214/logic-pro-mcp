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
