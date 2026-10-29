@preconcurrency import ApplicationServices
import Foundation

/// Connects the existing request-owned population reader to the shared file
/// flow. The capture's physical bindings are mandatory; wire rows cannot
/// recreate them. One instance of this runtime belongs to one operation.
@MainActor
enum MIDITrackExportProvider {
    private final class Session {
        var original: MIDITrackFileExport.Observation?
        var current: MIDITrackFileExport.Observation?
        var hold: MIDITrackNativeHold?
        var bindings: [AXTrackBinding.Binding] = []
        var exported = false
        var temporaryRenameActive = false
        var ended = false
    }

    static func makeRuntime(
        projectReference: String,
        acquire: @escaping @MainActor (SessionPopulationObservation.Request) async throws -> SessionPopulationObservation.Capture,
        nativeRuntime: AXLogicProElements.Runtime = .production,
        router: ChannelRouter? = nil,
        cache: StateCache? = nil,
        registry: TargetRegistry? = nil,
        liveTrackName: (@Sendable (Int) -> String?)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil
    ) -> MIDITrackFileExport.Runtime {
        let session = Session()
        let request = SessionPopulationObservation.Request(scope: .wholeProject, domains: [.tracks],
            allowUINavigation: false, projectRef: projectReference)
        var runtime = MIDITrackFileExport.Runtime(observe: {
            do {
                try SessionPopulationObservation.requireOwnedAcquisition()
                guard !session.ended else { throw MIDITrackFileExport.Failure.staleTarget }
                let capture = try await acquire(request)
                try SessionPopulationObservation.requireOwnedAcquisition()
                let report = SessionPopulationObservation.build(request: request, capture: capture)
                guard capture.requestedProjectMatches == true, report.project.status == .issued,
                      report.project.projectRef == projectReference else { throw MIDITrackFileExport.Failure.unboundProject }
                guard capture.freshPopulation?.stable == true, report.tracks.coverage == .complete,
                      report.tracks.rows.count == capture.tracks.count else {
                    throw MIDITrackFileExport.Failure.incompleteTrackPopulation
                }
                let observation = MIDITrackFileExport.Observation(projectReference: report.project.projectRef,
                    projectPath: report.project.filePath, coverage: report.tracks.coverage,
                    tracks: report.tracks.rows.map {
                        .init(index: $0.trackIndex, reference: $0.trackRef, name: $0.name)
                    })
                let bindings = capture.tracks.compactMap(\.physicalBinding)
                guard bindings.count == capture.tracks.count,
                      let candidate = MIDITrackNativeHold(observation: observation, bindings: bindings, runtime: nativeRuntime) else {
                    throw MIDITrackFileExport.Failure.staleTarget
                }
                if let current = session.current {
                    guard current == observation, session.hold?.isCurrent() == true else {
                        throw MIDITrackFileExport.Failure.staleTarget
                    }
                } else {
                    session.original = observation
                    session.current = observation
                    session.hold = candidate
                    session.bindings = bindings
                }
                return observation
            } catch {
                if !session.temporaryRenameActive { session.ended = true }
                throw error
            }
        }, stillCurrent: { observation in
            guard !session.ended, session.current == observation, session.hold?.isCurrent() == true else {
                if !session.temporaryRenameActive { session.ended = true }
                return false
            }
            return true
        }, exportAll: { destination, projectPath in
            try SessionPopulationObservation.requireOwnedAcquisition()
            guard !session.ended, !session.exported, let binding = session.bindings.first,
                  session.current?.projectPath == projectPath, session.hold?.isCurrent() == true else {
                throw MIDITrackFileExport.Failure.staleTarget
            }
            session.exported = true
            let panel = MIDITrackExportPanel(window: binding.window, document: binding.document,
                runtime: nativeRuntime, permittingAction: {
                    (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                })
            do { try await panel.exportAll(to: destination) }
            catch {
                if !session.temporaryRenameActive { session.ended = true }
                throw error
            }
        })
        guard let router, let cache, let registry, let liveTrackName, let liveTrackNames else {
            return runtime
        }
        runtime.beginTemporaryRename = { before, targetReference, temporaryName in
            try SessionPopulationObservation.requireOwnedAcquisition()
            guard !session.ended, !session.temporaryRenameActive,
                  session.current == before, session.hold?.isCurrent() == true,
                  let position = before.tracks.firstIndex(where: { $0.reference == targetReference }),
                  before.tracks.filter({ $0.reference == targetReference }).count == 1,
                  session.bindings.indices.contains(position),
                  Self.liveNamespaceMatches(before, reader: liveTrackNames) else {
                return .refusedBeforeWrite(detail: "temporary rename baseline was not current")
            }
            let source = before.tracks[position]
            let targetBinding = session.bindings[position]
            guard liveTrackName(source.index)?.utf8.elementsEqual(source.name.utf8) == true else {
                return .refusedBeforeWrite(detail: "temporary rename target was not current")
            }
            let project = TargetReference(rawValue: projectReference)
            let target = TargetReference(rawValue: targetReference)
            let receipt = await ExactTrackNameAdapter.apply(
                .init(projectReference: project, targetReference: target,
                      expectedBefore: source.name, desiredAfter: temporaryName),
                router: router, cache: cache, registry: registry,
                liveTrackName: liveTrackName, liveTrackNames: liveTrackNames)
            guard receipt.status == .applied, let inverse = receipt.inverse,
                  receipt.before?.utf8.elementsEqual(source.name.utf8) == true,
                  receipt.after?.utf8.elementsEqual(temporaryName.utf8) == true else {
                let residual = Self.boundTrackName(targetBinding)?.name
                if receipt.status == .rejectedBeforeWrite {
                    return .refusedBeforeWrite(detail: "verified rename provider refused before write")
                }
                session.ended = true
                return .unsettled(
                    residualName: residual,
                    cleanupStatus: .unconfirmed,
                    detail: "temporary rename effect was not verified with an owned inverse")
            }
            let renamed = Self.observation(before, replacing: position, withName: temporaryName)
            guard Self.liveNamespaceMatches(renamed, reader: liveTrackNames),
                  let rebound = await registry.resolve(target)?.physicalTrack,
                  rebound.matches(session.bindings[position]),
                  let renamedHold = MIDITrackNativeHold(
                    observation: renamed, bindings: session.bindings, runtime: nativeRuntime) else {
                let rollback = await ExactTrackNameAdapter.withOwnedTemporaryNameRestoration {
                    await ExactTrackNameAdapter.inverse(
                        inverse, router: router, liveTrackName: liveTrackName,
                        liveTrackNames: liveTrackNames)
                }
                session.ended = true
                return .unsettled(
                    residualName: Self.boundTrackName(targetBinding)?.name,
                    cleanupStatus: rollback.status == .applied ? .restored : .unconfirmed,
                    detail: rollback.status == .applied
                        ? "temporary rename lost physical target continuity and was rolled back"
                        : "temporary rename lost physical target continuity; restoration was unconfirmed")
            }
            session.current = renamed
            session.hold = renamedHold
            session.temporaryRenameActive = true
            return .acquired(.init(
                observation: renamed, originalName: source.name, temporaryName: temporaryName,
                restore: {
                    await ExactTrackNameAdapter.withOwnedTemporaryNameRestoration {
                        guard !session.ended, session.temporaryRenameActive else {
                            return .refused(
                                residualName: Self.boundTrackName(targetBinding)?.name,
                                detail: "temporary rename lease was already consumed")
                        }
                        // Consume exactly once before any inverse can be dispatched.
                        session.temporaryRenameActive = false
                        guard session.current == renamed,
                              Self.boundTrackName(targetBinding)?.name.utf8.elementsEqual(temporaryName.utf8) == true,
                              let rebound = await registry.resolve(target)?.physicalTrack,
                              rebound.matches(targetBinding) else {
                            session.ended = true
                            return .refused(
                                residualName: Self.boundTrackName(targetBinding)?.name,
                                detail: "owned temporary target or name changed before restoration")
                        }
                        let restoredReceipt = await ExactTrackNameAdapter.inverse(
                            inverse, router: router, liveTrackName: liveTrackName,
                            liveTrackNames: liveTrackNames)
                        guard restoredReceipt.status == .applied,
                              restoredReceipt.before?.utf8.elementsEqual(temporaryName.utf8) == true,
                              restoredReceipt.after?.utf8.elementsEqual(source.name.utf8) == true,
                              let rebound = await registry.resolve(target)?.physicalTrack,
                              rebound.matches(targetBinding),
                              let restored = Self.currentObservation(
                                from: before, bindings: session.bindings),
                              restored.observation.tracks.first(where: {
                                $0.reference == targetReference
                              })?.name.utf8.elementsEqual(source.name.utf8) == true,
                              let restoredHold = MIDITrackNativeHold(
                                observation: restored.observation, bindings: restored.bindings,
                                runtime: nativeRuntime) else {
                            session.ended = true
                            return .refused(
                                residualName: Self.boundTrackName(targetBinding)?.name,
                                detail: "owned temporary name restoration was not verified")
                        }
                        session.current = restored.observation
                        session.bindings = restored.bindings
                        session.hold = restoredHold
                        return .restored(restored.observation)
                    }
                }))
        }
        return runtime
    }

    private static func observation(
        _ observation: MIDITrackFileExport.Observation, replacing position: Int, withName name: String
    ) -> MIDITrackFileExport.Observation {
        var tracks = observation.tracks
        let source = tracks[position]
        tracks[position] = .init(index: source.index, reference: source.reference, name: name)
        return .init(
            projectReference: observation.projectReference, projectPath: observation.projectPath,
            coverage: observation.coverage, tracks: tracks)
    }

    private static func liveNamespaceMatches(
        _ observation: MIDITrackFileExport.Observation,
        reader: @Sendable () -> [Int: String]?
    ) -> Bool {
        guard let names = reader(), names.count == observation.tracks.count else { return false }
        return observation.tracks.allSatisfy { row in
            names[row.index]?.utf8.elementsEqual(row.name.utf8) == true
        }
    }

    private static func boundTrackName(_ binding: AXTrackBinding.Binding) -> (index: Int, name: String)? {
        guard let index = binding.currentIndex(),
              case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                from: binding.header, runtime: binding.runtime.ax),
              binding.currentIndex() == index else { return nil }
        return (index, name)
    }

    private static func currentObservation(
        from baseline: MIDITrackFileExport.Observation,
        bindings: [AXTrackBinding.Binding]
    ) -> (observation: MIDITrackFileExport.Observation, bindings: [AXTrackBinding.Binding])? {
        guard baseline.tracks.count == bindings.count else { return nil }
        var current: [(track: MIDITrackFileExport.Track, binding: AXTrackBinding.Binding)] = []
        current.reserveCapacity(bindings.count)
        for (row, binding) in zip(baseline.tracks, bindings) {
            guard let observed = boundTrackName(binding) else { return nil }
            current.append((.init(index: observed.index, reference: row.reference, name: observed.name), binding))
        }
        current.sort { $0.track.index < $1.track.index }
        guard Set(current.map(\.track.index)).count == current.count else { return nil }
        let observation = MIDITrackFileExport.Observation(
            projectReference: baseline.projectReference, projectPath: baseline.projectPath,
            coverage: baseline.coverage, tracks: current.map(\.track))
        return (observation, current.map(\.binding))
    }
}
