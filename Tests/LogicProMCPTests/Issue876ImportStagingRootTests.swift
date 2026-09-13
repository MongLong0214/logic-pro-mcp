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

    /// A staged file lands under the root the prefix advertises.
    ///
    /// Said exactly, because the first version of this comment said more than the code does: the
    /// import path check in `AccessibilityChannel.validatedMIDIImportPath` gates on
    /// `SMFWriter.isManagedTemporaryMIDIFile`, an in-memory registry of the files THIS PROCESS
    /// created — an identity, not a string prefix. Moving the staging root therefore cannot widen
    /// that boundary, and this test does not claim it guards one.
    /// `managedMIDIImportDirectoryPrefixes()` has no production caller today; what this pins is
    /// that the advertised prefix and the written path do not drift apart.
    /// The root must be a REAL directory this uid owns, not merely a path `createDirectory`
    /// returned without error. `withIntermediateDirectories: true` succeeds on a path that already
    /// exists — a symlink to somewhere else included — and applies the requested permissions only
    /// to what it actually creates. `$TMPDIR` never needed this check because macOS hands each
    /// user a per-boot 0700 directory; moving out of it gave that guarantee up.
    @Test("a symlink, a file, and a world-writable directory are all refused as a staging root",
          arguments: ["symlink", "file", "group-writable", "other-writable"])
    func aRootThatIsNotAPrivateOwnedDirectoryIsRefused(kind: String) throws {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("lpm-staging-root-probe-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        let candidate = scratch.appendingPathComponent("candidate")
        switch kind {
        case "symlink":
            let elsewhere = scratch.appendingPathComponent("elsewhere", isDirectory: true)
            try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: candidate, withDestinationURL: elsewhere)
        case "file":
            manager.createFile(atPath: candidate.path, contents: Data())
        case "group-writable":
            try manager.createDirectory(at: candidate, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o770])
        default:
            try manager.createDirectory(at: candidate, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o707])
        }

        #expect(!SMFWriter.isPrivateOwnedDirectory(candidate),
                "\(kind) was accepted as a staging root")
    }

    /// The control the three cases above need: the predicate must be able to say YES, or a
    /// refusal that refuses everything would look identical to a working check.
    @Test("a private directory this uid owns is accepted")
    func aPrivateOwnedDirectoryIsAccepted() throws {
        let manager = FileManager.default
        let candidate = manager.temporaryDirectory
            .appendingPathComponent("lpm-staging-root-ok-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: candidate, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: candidate) }
        #expect(SMFWriter.isPrivateOwnedDirectory(candidate))
    }

    @Test("a staged file sits under the advertised prefix")
    func aStagedFileSitsUnderTheAdvertisedPrefix() throws {
        let file = try SMFWriter.temporaryMIDIFile()
        defer { SMFWriter.cleanupTemporaryMIDIFile(file) }
        #expect(file.fileURL.path.hasPrefix(SMFWriter.temporaryDirectoryPrefix()))
    }
}
