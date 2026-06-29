import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #123 — file-open MIDI import occlusion → typed dialog_not_found
//
// #123 ("file-open MIDI import leaves Logic in a stale state") is ENVIRONMENTAL:
// when the File → Import → MIDI File open sheet never materialises (an occluded
// or otherwise unhealthy Logic session), `midi.import_file`
// (AccessibilityChannel.defaultImportMIDIFile) must FAIL CLOSED with a typed
// State C `dialog_not_found` — surfacing `file_open_dialog_seen:false` and
// naming the occluded/stale-session cause — rather than racing ahead, typing a
// path into the wrong field, and reporting a vacuous success against a leftover
// session.
//
// This suite LOCKS that contract. The honest path landed in the merged #140
// work; the assertions below guard against a future regression that silently
// re-introduces the stale-session false success.
//
// swift-testing footgun: Optional<Bool> assertions only hold under force-unwrap
// (`try #require(...)`), so every boolean flag is required-then-asserted; a
// `?? false` / `== .some(true)` style would be a DEAD assertion that always
// passes.

private func decodeIssue123JSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

private final class Issue123MIDIRegionReadbackSequence: @unchecked Sendable {
    private var values: [AccessibilityChannel.MIDIImportRegionReadback]
    private let lock = NSLock()

    init(_ values: [AccessibilityChannel.MIDIImportRegionReadback]) {
        self.values = values
    }

    func next() -> AccessibilityChannel.MIDIImportRegionReadback {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return .success([]) }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private func issue123MIDIRegion(trackIndex: Int) -> RegionInfo {
    RegionInfo(
        name: "Imported MIDI",
        trackIndex: trackIndex,
        startBar: 1,
        endBar: 2,
        kind: "midi",
        rawHelp: nil
    )
}

/// Write a minimal Standard MIDI File header into a managed import directory
/// so the path mirrors a real, validator-eligible
/// import target. `defaultImportMIDIFile` requires the file to EXIST before it
/// runs the AX flow, so the file must be on disk.
private func makeManagedMIDIFixture() throws -> SMFWriter.TemporaryMIDIFile {
    let tempFile = try SMFWriter.temporaryMIDIFile()
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile.fileURL)
    return tempFile
}

/// Spy that records how many times the track-count read-back fires. On the
/// occlusion path ONLY the before-count read must occur — once the dialog is
/// known absent there is nothing imported to verify.
private final class ImportCountSpy: @unchecked Sendable {
    private(set) var reads = 0
    let value: Int
    init(value: Int) { self.value = value }
    func read() -> Int {
        reads += 1
        return value
    }
}

// Both sentinels the production script can emit when the open panel never
// becomes usable map to the same fail-closed contract: the sheet never
// appearing, and the go-to-folder field never accepting the path. #123 must
// hold for either occlusion shape.
@Test(arguments: [
    #"{"result":"DIALOG_NOT_FOUND: file-open sheet did not appear"}"#,
    #"{"result":"DIALOG_NOT_FOUND: go-to-folder field did not accept the path"}"#,
])
func testOccludedSessionFailsClosedWithDialogNotFound(sentinel: String) async throws {
    let fixture = try makeManagedMIDIFixture()
    defer { SMFWriter.cleanupTemporaryMIDIFile(fixture) }

    // Pre-condition: the fixture really lives under the managed import dir, so
    // this is a faithful #123 scenario (a valid target, occluded session) and
    // not a missing-file short-circuit.
    let validated = AccessibilityChannel.validatedMIDIImportPath(fixture.fileURL.path)
    #expect(validated != nil, "fixture must be a managed, validator-eligible import target")

    let spy = ImportCountSpy(value: 9)

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: fixture.fileURL.path,
        executeScript: { _ in .success(sentinel) },
        trackCount: { spy.read() },
        trackNames: { [] },
        regionInfos: { .success([]) },
        deltaPoll: {}
    )

    // Must be a hard failure — NOT a false success against the leftover session.
    #expect(!result.isSuccess, "occluded session must fail closed, never report a vacuous success")

    let obj = decodeIssue123JSON(result.message)

    // Typed State C dialog_not_found.
    #expect(obj["error"] as? String == "dialog_not_found")
    #expect(obj["missing_element"] as? String == "file_open_sheet")

    // The open sheet was never seen — the load-bearing #123 flag (force-unwrap;
    // an Optional<Bool> compare would be a dead assertion).
    let fileOpenSeen = try #require(obj["file_open_dialog_seen"] as? Bool)
    #expect(!fileOpenSeen)
    let tempoSeen = try #require(obj["tempo_dialog_seen"] as? Bool)
    #expect(!tempoSeen)

    // Hint must name the occluded / stale-session cause so the caller knows the
    // failure is environmental (the heart of #123), not a server defect.
    let hint = try #require(obj["hint"] as? String)
    #expect(hint.contains("occluded") || hint.contains("unhealthy"))
    #expect(hint.contains("never appeared"))

    // dialog_not_found is terminal: the router must surface it verbatim and not
    // fall through to a next-channel success that would re-create the stale
    // success #123 reported.
    #expect(HonestContract.terminalErrorCodes.contains("dialog_not_found"))

    // No import happened, so only the before-count read should fire; a delta
    // read here would mean we proceeded past a known-absent dialog.
    #expect(spy.reads == 1, "only the before-count read should occur on the occlusion path")
}

// Positive contrast: a CLEAN session (sheet appeared, track created) is a
// verified State A success. This proves the gate above is not trivially
// always-failing — the occlusion fail-closed is specific to the missing sheet.
@Test func testCleanSessionVerifiesImportStateAAndSeesDialog() async throws {
    let fixture = try makeManagedMIDIFixture()
    defer { SMFWriter.cleanupTemporaryMIDIFile(fixture) }

    final class Counter: @unchecked Sendable {
        var values = [4, 5]
        func next() -> Int { values.removeFirst() }
    }
    let counter = Counter()
    let regions = Issue123MIDIRegionReadbackSequence([
        .success([]),
        .success([issue123MIDIRegion(trackIndex: 4)]),
    ])

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: fixture.fileURL.path,
        executeScript: { _ in .success("OK") },
        trackCount: { counter.next() },
        trackNames: { ["Studio Grand", "01 Felt Keys", "02 Bass", "03 Drums", "04 Imported Lead"] },
        regionInfos: { regions.next() },
        deltaPoll: {}
    )

    #expect(result.isSuccess)
    let obj = decodeIssue123JSON(result.message)
    let verified = try #require(obj["verified"] as? Bool)
    #expect(verified)
    let fileOpenSeen = try #require(obj["file_open_dialog_seen"] as? Bool)
    #expect(fileOpenSeen)
    #expect(obj["observed_delta"] as? Int == 1)
    #expect(obj["error"] == nil)
}
