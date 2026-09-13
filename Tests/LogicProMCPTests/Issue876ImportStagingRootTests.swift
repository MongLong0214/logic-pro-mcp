import Foundation
import Testing
@testable import LogicProMCP

/// The staged .mid file's HOME is a correctness property of `record_sequence`, not housekeeping.
///
/// `record_sequence` hands the staged path to Logic's File ▸ Import ▸ MIDI File open panel, and
/// that panel is a column view: to show the file it enumerates the file's parent directory. Under
/// the shared user temporary directory that parent belongs to every process on the machine —
/// measured 2026-09-13 at 114,000 entries — and the panel never finishes.
///
/// Measured in ONE panel, seconds apart, by reading the panel's own state: a path under `$TMPDIR`
/// left `Import=false` with an `AXBusyIndicator` and a `Loading…` label still present after thirty
/// seconds; a path whose ancestors are all small came back `Import=true`, no busy indicator, no
/// label, immediately. On a freshly launched Logic the staged-in-Caches build then imported
/// successfully four times out of four, first attempt included, where the previous build needed
/// five attempts.
@Suite("Issue876 the staged MIDI file does not live in the shared temporary directory")
struct Issue876ImportStagingRootTests {
    @Test("the staging root is not the shared user temporary directory")
    func stagingRootIsNotTheSharedTemporaryDirectory() {
        let staging = SMFWriter.importStagingRoot().resolvingSymlinksInPath().standardizedFileURL.path
        let shared = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        #expect(staging != shared,
                "staging root fell back to \(shared); the open panel has to enumerate that directory")
    }

    /// Not just a different directory — one whose ANCESTORS are small. A root placed directly
    /// inside the shared temporary directory would pass the check above and fail live, because it
    /// is the parent column the panel renders.
    @Test("no ancestor of the staging root is the shared temporary directory")
    func noAncestorOfTheStagingRootIsTheSharedTemporaryDirectory() {
        let shared = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        var ancestor = SMFWriter.importStagingRoot().resolvingSymlinksInPath().standardizedFileURL
        while ancestor.path != "/" {
            ancestor = ancestor.deletingLastPathComponent()
            #expect(ancestor.path != shared,
                    "\(shared) is an ancestor of the staging root; the panel renders that column")
        }
    }

    /// A staged file lands under the root the prefix advertises, so the import path allowlist in
    /// `AccessibilityChannel.managedMIDIImportDirectoryPrefixes()` keeps matching what is written.
    @Test("a staged file sits under the advertised prefix")
    func aStagedFileSitsUnderTheAdvertisedPrefix() throws {
        let file = try SMFWriter.temporaryMIDIFile()
        defer { SMFWriter.cleanupTemporaryMIDIFile(file) }
        #expect(file.fileURL.path.hasPrefix(SMFWriter.temporaryDirectoryPrefix()))
    }
}
