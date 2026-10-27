import Foundation
import Testing
@testable import LogicProMCP

private func midiTrackExportBytes(_ tracks: [(String, UInt8)]) -> Data {
    func chunk(_ owner: String?, pitch: UInt8?) -> [UInt8] {
        var events: [UInt8] = []
        if let owner { events += [0, 0xFF, 4, UInt8(owner.utf8.count)] + owner.utf8 }
        if let pitch { events += [0, 0x90, pitch, 100, 1, 0x80, pitch, 0] }
        events += [0, 0xFF, 0x2F, 0]
        return [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, UInt8(events.count)] + events
    }
    let header: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0,
        UInt8(tracks.count + 1), 1, 0xE0]
    return Data(header + chunk(nil, pitch: nil) + tracks.flatMap { chunk($0.0, pitch: $0.1) })
}

@MainActor
private final class MIDIFileExportFixture {
    var observations = 0
    var exports = 0
    var exportedURL: URL?
    var fault = ""
    var raceDestination: URL?
    var artifactSymlinkSource: URL?
    let bytes: Data

    init() {
        bytes = midiTrackExportBytes([("Target", 60), ("Peer", 72)])
    }

    var runtime: MIDITrackFileExport.Runtime {
        .init(observe: {
            self.observations += 1
            if self.fault == "cancel_after_read" && self.observations == 2 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            var rows = [MIDITrackFileExport.Track(index: 0, reference: "trk_target", name: "Target"),
                        .init(index: 1, reference: "trk_peer", name: "Peer")]
            if self.fault == "duplicate_name" { rows[1] = .init(index: 1, reference: "trk_peer", name: "Target") }
            if self.fault == "changed_target" && self.observations > 1 {
                rows[0] = .init(index: 0, reference: "trk_replacement", name: "Target")
            }
            return .init(projectReference: self.fault == "wrong_project" ? "prj_other" : "prj_current",
                projectPath: "/fixture.logicx", coverage: self.fault == "partial" ? .partial : .complete,
                tracks: rows)
        }, stillCurrent: { _ in self.fault != "custody_lost" || self.exports == 0 }, exportAll: { url, _ in
            self.exports += 1
            self.exportedURL = url
            if let source = self.artifactSymlinkSource {
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source)
                return
            }
            if let destination = self.raceDestination {
                try Data([0xCE, 0xFA]).write(to: destination, options: .withoutOverwriting)
            }
            if self.fault == "cancel" { throw MIDITrackFileExport.Failure.exportCancelled }
            if self.fault != "no_artifact" {
                try (self.fault == "bad_artifact" ? Data([1, 2, 3]) : self.bytes).write(to: url, options: .withoutOverwriting)
            }
        })
    }
}

@MainActor
private final class TemporaryRenameFileExportFixture {
    var rows: [MIDITrackFileExport.Track] = [
        .init(index: 4, reference: "trk_target", name: "Repeated"),
        .init(index: 5, reference: "trk_peer", name: "Repeated"),
        .init(index: 6, reference: "trk_other", name: "Other"),
    ]
    var renameStarts = 0
    var restorations = 0
    var exports = 0
    var fault = ""
    var temporaryName: String?

    var observation: MIDITrackFileExport.Observation {
        .init(projectReference: "prj_current", projectPath: "/fixture.logicx",
              coverage: .complete, tracks: rows)
    }

    var runtime: MIDITrackFileExport.Runtime {
        .init(observe: { self.observation }, stillCurrent: { observed in
            observed == self.observation
        }, exportAll: { url, _ in
            self.exports += 1
            if self.fault == "export_failure" { throw MIDITrackFileExport.Failure.exportCancelled }
            let tracks = self.rows.compactMap { row -> (String, UInt8)? in
                if self.fault == "omitted_target", row.reference == "trk_target" { return nil }
                let pitch: UInt8 = row.reference == "trk_target" ? 60 : (row.reference == "trk_peer" ? 72 : 74)
                return (row.name, pitch)
            }
            try midiTrackExportBytes(tracks).write(to: url, options: .withoutOverwriting)
            if self.fault == "cancel_after_export" { withUnsafeCurrentTask { $0?.cancel() } }
        }, beginTemporaryRename: { before, targetReference, temporaryName in
            self.renameStarts += 1
            #expect(before == self.observation)
            #expect(targetReference == "trk_target")
            #expect(!self.rows.contains { $0.name == temporaryName })
            self.temporaryName = temporaryName
            self.rows[0] = .init(index: 4, reference: "trk_target", name: temporaryName)
            var renamedRows = self.rows
            if self.fault == "invalid_acquired_observation" {
                renamedRows[1] = .init(index: 5, reference: "trk_peer", name: "Unexpected")
            }
            let renamed = MIDITrackFileExport.Observation(
                projectReference: "prj_current", projectPath: "/fixture.logicx",
                coverage: .complete, tracks: renamedRows)
            return .acquired(.init(observation: renamed, originalName: "Repeated",
                temporaryName: temporaryName, restore: {
                    self.restorations += 1
                    if self.fault == "user_rename_before_restore" {
                        self.rows[0] = .init(index: 4, reference: "trk_target", name: "User Edit")
                        return .refused(residualName: "User Edit", detail: "owned temporary name changed")
                    }
                    if self.fault == "target_replaced_before_restore" {
                        self.rows[0] = .init(index: 4, reference: "trk_replacement", name: temporaryName)
                        return .refused(residualName: temporaryName, detail: "physical target changed")
                    }
                    if self.fault == "restore_refused" {
                        return .refused(residualName: temporaryName, detail: "inverse refused")
                    }
                    self.rows[0] = .init(index: 4, reference: "trk_target", name: "Repeated")
                    return .restored(self.observation)
                }))
        })
    }
}

@MainActor @Test func midiTrackFileExportRestoresAnAcquiredRenameWhoseObservationIsInvalid() async {
    let fixture = TemporaryRenameFileExportFixture()
    fixture.fault = "invalid_acquired_observation"
    do {
        _ = try await MIDITrackFileExport.run(
            projectReference: "prj_current", targetReference: "trk_target", destination: nil,
            allowTemporaryTrackRename: true, runtime: fixture.runtime)
        Issue.record("An invalid acquired observation was accepted")
    } catch let failure as MIDITrackFileExport.Failure {
        guard case .temporaryRenamePreparationUnconfirmed(
            originalName: "Repeated", temporaryName: _, residualName: "Repeated",
            cleanupStatus: .restored, detail: _
        ) = failure else {
            Issue.record("Unexpected failure: \(failure)")
            return
        }
    } catch {
        Issue.record("Unexpected failure: \(error)")
    }
    #expect(fixture.rows[0].name == "Repeated")
    #expect(fixture.renameStarts == 1 && fixture.exports == 0 && fixture.restorations == 1)
}

@MainActor @Test func midiTrackFileReadReusesExportAndCleansOnlyItsManagedTemporaryFile() async throws {
    let fixture = MIDIFileExportFixture()
    let result = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
        destination: nil, runtime: fixture.runtime)
    #expect(fixture.exports == 1 && fixture.observations == 2)
    #expect(result.document.notes.map(\.pitch) == [60])
    #expect(result.document.ticksPerQuarter == 480 && result.document.trackCount == 2)
    let temporary = try #require(fixture.exportedURL)
    #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
}

@Test func midiTrackFileReadCanReturnToANonUIActorCaller() async throws {
    let fixture = await MIDIFileExportFixture()
    let runtime = await fixture.runtime
    let result = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
        destination: nil, runtime: runtime)
    #expect(result.document.notes.map(\.pitch) == [60])
}

@Test func midiWholeProjectExportLeafIsDistinctFromSelectionAndKeyCommandNames() {
    let labels = AXLocalePolicy.allMIDITracksAsMIDIFileMenuItem
    #expect(labels.matches("모든 MIDI 트랙을 MIDI 파일로…", mode: .exactStrict))
    #expect(labels.matches("All MIDI Tracks as MIDI File…", mode: .exactStrict))
    #expect(!labels.matches("선택 범위를 MIDI 파일로…", mode: .exactStrict))
    #expect(!labels.matches("Export All MIDI Tracks as MIDI File…", mode: .exactStrict))
}

@MainActor @Test func midiTrackFileExportPublishesOnlyTheBoundTrackWithoutReplacingFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("target.mid").path
    let fixture = MIDIFileExportFixture()
    _ = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
        destination: path, runtime: fixture.runtime)
    #expect(try SMFReader.parseDocument(Data(contentsOf: URL(fileURLWithPath: path))).notes.map(\.pitch) == [60])
    let preserved = try Data(contentsOf: URL(fileURLWithPath: path))
    do {
        _ = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: path, runtime: fixture.runtime)
        Issue.record("An existing destination was replaced")
    } catch { #expect(error as? MIDITrackFileExport.Failure == .destinationExists) }
    #expect(fixture.exports == 1)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == preserved)
}

@MainActor @Test(arguments: ["wrong_project", "partial", "duplicate_name", "changed_target", "custody_lost", "cancel", "no_artifact", "bad_artifact"])
func midiTrackFileExportRefusesIdentityAndArtifactFailuresWithoutPublishing(fault: String) async throws {
    let fixture = MIDIFileExportFixture()
    fixture.fault = fault
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("must-not-exist.mid").path
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output, runtime: fixture.runtime)
    }
    #expect(!FileManager.default.fileExists(atPath: output))
    #expect(fixture.exports == (["wrong_project", "partial", "duplicate_name"].contains(fault) ? 0 : 1))
    if let temporary = fixture.exportedURL {
        #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
    }
}

@MainActor @Test(arguments: ["relative.mid", "/missing-parent/target.mid", "/fixture.txt"])
func midiTrackFileExportRefusesInvalidPathsBeforeReadingLogic(path: String) async {
    let fixture = MIDIFileExportFixture()
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: path, runtime: fixture.runtime)
    }
    #expect(fixture.observations == 0 && fixture.exports == 0)
}

@MainActor @Test func midiTrackFileExportDoesNotOverwriteADestinationCreatedDuringNativeExport() async throws {
    let fixture = MIDIFileExportFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("raced.mid")
    fixture.raceDestination = output
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output.path, runtime: fixture.runtime)
    }
    #expect(try Data(contentsOf: output) == Data([0xCE, 0xFA]))
}

@MainActor @Test func midiTrackFileExportStopsCancellationDuringTheFinalObservation() async throws {
    let fixture = MIDIFileExportFixture()
    fixture.fault = "cancel_after_read"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("cancelled.mid")
    let result = await Task { @MainActor in
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output.path, runtime: fixture.runtime)
    }.result
    switch result {
    case .success: Issue.record("Cancelled final observation still published an artifact")
    case .failure(let error): #expect(error is CancellationError)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    let temporary = try #require(fixture.exportedURL)
    #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
}

@MainActor @Test func midiTrackFileExportRefusesASymlinkArtifactAndLeavesItsTargetUntouched() async throws {
    let fixture = MIDIFileExportFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let unrelated = directory.appendingPathComponent("unrelated.mid")
    try fixture.bytes.write(to: unrelated, options: .withoutOverwriting)
    fixture.artifactSymlinkSource = unrelated
    let output = directory.appendingPathComponent("must-not-exist.mid")
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output.path, runtime: fixture.runtime)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try Data(contentsOf: unrelated) == fixture.bytes)
}

@MainActor @Test func midiTrackFileExportReportsAllCollidingArrangeIndicesWithoutRenamingByDefault() async {
    let fixture = TemporaryRenameFileExportFixture()
    do {
        _ = try await MIDITrackFileExport.run(
            projectReference: "prj_current", targetReference: "trk_target", destination: nil,
            allowTemporaryTrackRename: false, runtime: fixture.runtime)
        Issue.record("A repeated name was exported without explicit rename consent")
    } catch let failure as MIDITrackFileExport.Failure {
        #expect(failure == .ambiguousTarget(indices: [4, 5]))
    } catch {
        Issue.record("Unexpected failure: \(error)")
    }
    #expect(fixture.renameStarts == 0 && fixture.exports == 0 && fixture.restorations == 0)
}

@MainActor @Test func midiTrackFileExportUsesAndRestoresAnExplicitTemporaryNameBeforeSuccess() async throws {
    let fixture = TemporaryRenameFileExportFixture()
    let result = try await MIDITrackFileExport.run(
        projectReference: "prj_current", targetReference: "trk_target", destination: nil,
        allowTemporaryTrackRename: true, runtime: fixture.runtime)
    #expect(result.document.notes.map(\.pitch) == [60])
    let report = try #require(result.temporaryRename)
    #expect(report.originalName == "Repeated")
    #expect(report.temporaryName == fixture.temporaryName)
    #expect(report.restoration == "restored")
    #expect(fixture.rows[0].name == "Repeated")
    #expect(fixture.renameStarts == 1 && fixture.exports == 1 && fixture.restorations == 1)
}

@MainActor @Test func midiTrackFileExportLeavesTheUniqueNamePathByteForByteNonMutating() async throws {
    let fixture = MIDIFileExportFixture()
    let result = try await MIDITrackFileExport.run(
        projectReference: "prj_current", targetReference: "trk_target", destination: nil,
        allowTemporaryTrackRename: true, runtime: fixture.runtime)
    #expect(result.document.notes.map(\.pitch) == [60])
    #expect(result.temporaryRename == nil)
    #expect(fixture.exports == 1)
}

@MainActor @Test(arguments: ["export_failure", "omitted_target"])
func midiTrackFileExportRestoresTheOriginalAfterExportFailures(fault: String) async {
    let fixture = TemporaryRenameFileExportFixture()
    fixture.fault = fault
    do {
        _ = try await MIDITrackFileExport.run(
            projectReference: "prj_current", targetReference: "trk_target", destination: nil,
            allowTemporaryTrackRename: true, runtime: fixture.runtime)
        Issue.record("A failed export reported success")
    } catch let failure as MIDITrackFileExport.RestoredTemporaryRenameFailure {
        #expect(failure.originalName == "Repeated")
        #expect(failure.temporaryName == fixture.temporaryName)
        #expect(failure.residualName == "Repeated")
    } catch {
        Issue.record("Restored cleanup metadata was lost: \(error)")
    }
    #expect(fixture.rows[0].name == "Repeated")
    #expect(fixture.renameStarts == 1 && fixture.exports == 1 && fixture.restorations == 1)
}

@MainActor @Test func midiTrackFileExportRestoresTheOriginalAfterTaskCancellation() async {
    let fixture = TemporaryRenameFileExportFixture()
    fixture.fault = "cancel_after_export"
    let result = await Task { @MainActor in
        try await MIDITrackFileExport.run(
            projectReference: "prj_current", targetReference: "trk_target", destination: nil,
            allowTemporaryTrackRename: true, runtime: fixture.runtime)
    }.result
    switch result {
    case .success: Issue.record("A cancelled export reported success")
    case .failure(let error):
        guard let failure = error as? MIDITrackFileExport.RestoredTemporaryRenameFailure else {
            Issue.record("Restored cleanup metadata was lost: \(error)")
            return
        }
        #expect(failure.primary is CancellationError)
        #expect(failure.residualName == "Repeated")
    }
    #expect(fixture.rows[0].name == "Repeated")
    #expect(fixture.restorations == 1)
}

@MainActor @Test(arguments: ["user_rename_before_restore", "target_replaced_before_restore", "restore_refused"])
func midiTrackFileExportNeverOverwritesForeignStateAndReportsResidualCleanup(fault: String) async throws {
    let fixture = TemporaryRenameFileExportFixture()
    fixture.fault = fault
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("must-not-publish.mid")
    do {
        _ = try await MIDITrackFileExport.run(
            projectReference: "prj_current", targetReference: "trk_target", destination: output.path,
            allowTemporaryTrackRename: true, runtime: fixture.runtime)
        Issue.record("Unconfirmed restoration reported verified success")
    } catch let failure as MIDITrackFileExport.Failure {
        guard case .temporaryRenameRestorationUnconfirmed(
            originalName: "Repeated", temporaryName: let temporary,
            residualName: let residual, detail: _, primary: _
        ) = failure else {
            Issue.record("Unexpected failure: \(failure)")
            return
        }
        #expect(temporary == fixture.temporaryName)
        #expect(residual == (fault == "user_rename_before_restore" ? "User Edit" : temporary))
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(fixture.restorations == 1)
    if fault == "user_rename_before_restore" { #expect(fixture.rows[0].name == "User Edit") }
}
