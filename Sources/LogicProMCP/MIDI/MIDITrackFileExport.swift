import Foundation
import Darwin

/// Shared file flow for a native whole-project MIDI export and a target-only
/// artifact/read. Native acquisition supplies completeness and held-object
/// continuity; file names alone never supply that authority. Not a public API.
@MainActor
enum MIDITrackFileExport {
    struct Track: Equatable, Sendable {
        let index: Int
        let reference: String?
        let name: String
    }

    struct Observation: Equatable, Sendable {
        let projectReference: String?
        let projectPath: String?
        let coverage: SessionPopulationObservation.Coverage
        let tracks: [Track]
    }

    struct Runtime {
        var observe: @MainActor () async throws -> Observation
        /// Checks the actual retained native window/headers, not just row text.
        var stillCurrent: @MainActor (Observation) async -> Bool
        /// Writes only to the new process-owned private destination. It must
        /// throw on cancellation or an unresolved export dialog, never retry.
        var exportAll: @MainActor (URL, String) async throws -> Void
        /// Optional, exact native rename acquisition. A refusal must distinguish
        /// a proven zero-write exit from an unsettled possible effect.
        var beginTemporaryRename: (@MainActor (
            Observation, String, String
        ) async throws -> TemporaryRenameAcquisition)? = nil
    }

    enum Failure: Error, Equatable {
        case invalidDestination, destinationExists, unboundProject
        case incompleteTrackPopulation, staleTarget
        case ambiguousTarget(indices: [Int])
        case temporaryRenameUnavailable(indices: [Int])
        case temporaryRenamePreparationUnconfirmed(
            originalName: String, temporaryName: String, residualName: String?,
            cleanupStatus: TemporaryRenameCleanupStatus, detail: String)
        case temporaryRenameRestorationUnconfirmed(
            originalName: String, temporaryName: String, residualName: String?, detail: String, primary: String?)
        case exportCancelled, unreadableArtifact
    }

    enum TemporaryRenameCleanupStatus: String, Equatable, Sendable {
        case restored, unconfirmed
    }

    struct RestoredTemporaryRenameFailure: Error, @unchecked Sendable {
        let originalName: String
        let temporaryName: String
        let residualName: String
        let primary: any Error
    }

    enum TemporaryRenameRestoration: Equatable, Sendable {
        case restored(Observation)
        case refused(residualName: String?, detail: String)
    }

    struct TemporaryRenameLease {
        let observation: Observation
        let originalName: String
        let temporaryName: String
        let restore: @MainActor () async -> TemporaryRenameRestoration
    }

    enum TemporaryRenameAcquisition {
        case acquired(TemporaryRenameLease)
        case refusedBeforeWrite(detail: String)
        case unsettled(
            residualName: String?, cleanupStatus: TemporaryRenameCleanupStatus, detail: String)
    }

    struct TemporaryRenameReport: Equatable, Sendable {
        let originalName: String
        let temporaryName: String
        let restoration: String
    }

    struct Result {
        let document: SMFReader.Document
        let temporaryRename: TemporaryRenameReport?

        init(document: SMFReader.Document, temporaryRename: TemporaryRenameReport? = nil) {
            self.document = document
            self.temporaryRename = temporaryRename
        }
    }

    static func run(projectReference: String, targetReference: String, destination: String?,
                    allowTemporaryTrackRename: Bool = false, runtime: Runtime) async throws -> Result {
        let output = try destination.map(validateDestination)
        let before = try await runtime.observe()
        let bound = try boundTarget(
            before, projectReference: projectReference, targetReference: targetReference)
        guard await runtime.stillCurrent(before) else { throw Failure.staleTarget }
        try Task.checkCancellation()

        var lease: TemporaryRenameLease?
        var working = before
        var exportName = bound.track.name
        var restorationAttempted = false
        var restorationReport: TemporaryRenameReport?
        do {
            if bound.collidingIndices.count > 1 {
                guard allowTemporaryTrackRename else {
                    throw Failure.ambiguousTarget(indices: bound.collidingIndices)
                }
                guard let begin = runtime.beginTemporaryRename else {
                    throw Failure.temporaryRenameUnavailable(indices: bound.collidingIndices)
                }
                let temporaryName = collisionFreeTemporaryName(in: before)
                switch try await begin(before, targetReference, temporaryName) {
                case .refusedBeforeWrite:
                    throw Failure.temporaryRenameUnavailable(indices: bound.collidingIndices)
                case .unsettled(let residualName, let cleanupStatus, let detail):
                    throw Failure.temporaryRenamePreparationUnconfirmed(
                        originalName: bound.track.name, temporaryName: temporaryName,
                        residualName: residualName, cleanupStatus: cleanupStatus, detail: detail)
                case .acquired(let acquired):
                    // The provider may already have changed native state. Retain its
                    // inverse before validating any returned observation so every
                    // post-acquisition failure goes through the cleanup path below.
                    lease = acquired
                    let expected = observation(
                        before, replacing: bound.position, withName: temporaryName)
                    guard acquired.originalName.utf8.elementsEqual(bound.track.name.utf8),
                          acquired.temporaryName.utf8.elementsEqual(temporaryName.utf8),
                          acquired.observation == expected else {
                        throw Failure.temporaryRenamePreparationUnconfirmed(
                            originalName: bound.track.name, temporaryName: temporaryName,
                            residualName: acquired.temporaryName,
                            cleanupStatus: .unconfirmed,
                            detail: "temporary rename observation mismatch")
                    }
                    let renamed = try boundTarget(
                        acquired.observation, projectReference: projectReference,
                        targetReference: targetReference)
                    guard renamed.position == bound.position,
                          renamed.track.index == bound.track.index,
                          renamed.track.name.utf8.elementsEqual(temporaryName.utf8),
                          renamed.collidingIndices == [bound.track.index],
                          await runtime.stillCurrent(acquired.observation) else {
                        throw Failure.temporaryRenamePreparationUnconfirmed(
                            originalName: bound.track.name, temporaryName: temporaryName,
                            residualName: acquired.temporaryName,
                            cleanupStatus: .unconfirmed,
                            detail: "temporary rename was not current")
                    }
                    working = acquired.observation
                    exportName = temporaryName
                }
            }

            let temporary = try ExportTemporaryFiles.temporaryExportFile()
            defer { ExportTemporaryFiles.cleanupTemporaryExportFile(temporary) }
            guard let projectPath = working.projectPath else { throw Failure.unboundProject }
            try await runtime.exportAll(temporary.fileURL, projectPath)
            try Task.checkCancellation()
            guard await runtime.stillCurrent(working) else { throw Failure.staleTarget }

            let after = try await runtime.observe()
            _ = try boundTarget(
                after, projectReference: projectReference, targetReference: targetReference)
            guard working == after, await runtime.stillCurrent(working),
                  await runtime.stillCurrent(after) else { throw Failure.staleTarget }
            try Task.checkCancellation()
            let exported = try readRegularArtifact(temporary.fileURL)
            let selected = try SMFReader.extractTracks(namedInstrument: exportName, from: exported)
            let document = try SMFReader.parseDocument(selected)

            var report: TemporaryRenameReport?
            if let lease {
                restorationAttempted = true
                let restored = await Task { @MainActor in await lease.restore() }.value
                report = try await verifiedRestoration(
                    restored, lease: lease, expected: before, projectReference: projectReference,
                    targetReference: targetReference, runtime: runtime, primary: nil)
                restorationReport = report
            }
            // The output is copied from the validated private artifact only after
            // any owned temporary name is proved restored. A raced file or symlink
            // is never replaced.
            try Task.checkCancellation()
            if let output { try selected.write(to: output, options: .withoutOverwriting) }
            return Result(document: document, temporaryRename: report)
        } catch {
            if let lease, !restorationAttempted {
                restorationAttempted = true
                let restored = await Task { @MainActor in await lease.restore() }.value
                restorationReport = try await verifiedRestoration(
                    restored, lease: lease, expected: before, projectReference: projectReference,
                    targetReference: targetReference, runtime: runtime,
                    primary: String(describing: error))
                if case .temporaryRenamePreparationUnconfirmed(
                    let originalName, let temporaryName, _, _, let detail
                ) = error as? Failure {
                    throw Failure.temporaryRenamePreparationUnconfirmed(
                        originalName: originalName, temporaryName: temporaryName,
                        residualName: lease.originalName, cleanupStatus: .restored,
                        detail: detail)
                }
                throw RestoredTemporaryRenameFailure(
                    originalName: lease.originalName, temporaryName: lease.temporaryName,
                    residualName: lease.originalName, primary: error)
            }
            if let report = restorationReport {
                throw RestoredTemporaryRenameFailure(
                    originalName: report.originalName, temporaryName: report.temporaryName,
                    residualName: report.originalName, primary: error)
            }
            throw error
        }
    }

    private struct BoundTarget {
        let position: Int
        let track: Track
        let collidingIndices: [Int]
    }

    private static func verifiedRestoration(
        _ restoration: TemporaryRenameRestoration, lease: TemporaryRenameLease,
        expected: Observation, projectReference: String, targetReference: String,
        runtime: Runtime, primary: String?
    ) async throws -> TemporaryRenameReport {
        switch restoration {
        case .refused(let residualName, let detail):
            throw Failure.temporaryRenameRestorationUnconfirmed(
                originalName: lease.originalName, temporaryName: lease.temporaryName,
                residualName: residualName, detail: detail, primary: primary)
        case .restored(let observed):
            let target = try? boundTarget(
                observed, projectReference: projectReference, targetReference: targetReference)
            guard observed == expected, target?.track.name == lease.originalName,
                  await runtime.stillCurrent(observed) else {
                throw Failure.temporaryRenameRestorationUnconfirmed(
                    originalName: lease.originalName, temporaryName: lease.temporaryName,
                    residualName: target?.track.name, detail: "restored namespace was not current",
                    primary: primary)
            }
            return .init(
                originalName: lease.originalName, temporaryName: lease.temporaryName,
                restoration: "restored")
        }
    }

    private static func observation(
        _ observation: Observation, replacing position: Int, withName name: String
    ) -> Observation {
        var tracks = observation.tracks
        let target = tracks[position]
        tracks[position] = .init(index: target.index, reference: target.reference, name: name)
        return .init(
            projectReference: observation.projectReference, projectPath: observation.projectPath,
            coverage: observation.coverage, tracks: tracks)
    }

    private static func collisionFreeTemporaryName(in observation: Observation) -> String {
        while true {
            let candidate = "LPMCP-\(UUID().uuidString)"
            if !observation.tracks.contains(where: { $0.name.utf8.elementsEqual(candidate.utf8) }) {
                return candidate
            }
        }
    }

    private static func readRegularArtifact(_ url: URL) throws -> Data {
        // Bind the read to the opened regular file; a metadata check followed
        // by Data(contentsOf:) would still follow a raced symlink.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.unreadableArtifact }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Failure.unreadableArtifact
        }
        do { return try handle.readToEnd() ?? Data() }
        catch { throw Failure.unreadableArtifact }
    }

    private static func boundTarget(_ observation: Observation, projectReference: String,
                                    targetReference: String) throws -> BoundTarget {
        guard !projectReference.isEmpty, observation.projectReference == projectReference,
              let path = observation.projectPath, path.hasPrefix("/"), !path.contains("\0") else {
            throw Failure.unboundProject
        }
        guard observation.coverage == .complete else { throw Failure.incompleteTrackPopulation }
        let matches = observation.tracks.enumerated().filter { $0.element.reference == targetReference }
        guard !targetReference.isEmpty, matches.count == 1, let match = matches.first,
              match.element.index >= 0,
              Set(observation.tracks.map(\.index)).count == observation.tracks.count else {
            throw Failure.staleTarget
        }
        let target = match.element
        guard !target.name.isEmpty else { throw Failure.staleTarget }
        let collisions = observation.tracks.filter {
            $0.name.utf8.elementsEqual(target.name.utf8)
        }.map(\.index).sorted()
        return .init(position: match.offset, track: target, collidingIndices: collisions)
    }

    private static func validateDestination(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.invalidDestination }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "mid" else { throw Failure.invalidDestination }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &directory),
              directory.boolValue else { throw Failure.invalidDestination }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            throw Failure.destinationExists
        } catch let error as Failure { throw error }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
        catch { throw Failure.invalidDestination }
        return url
    }
}
