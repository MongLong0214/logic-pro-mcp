import Foundation
import MCP

/// #968 N1: one exact-local Arrange name action, not a coupled naming plan executor.
/// The canonical repair planner's preservation-footprint blocker remains authoritative.
enum ExactTrackNameAdapter {
    @TaskLocal private static var coupledWriteBoundary: (@Sendable (Bool) -> Bool)?

    static func coupledWritePermitted(allowOwnPreview: Bool = false) -> Bool {
        coupledWriteBoundary?(allowOwnPreview) ?? true
    }
    struct Action: Sendable {
        let projectReference: TargetReference
        let targetReference: TargetReference
        let expectedBefore: String
        let desiredAfter: String
    }

    enum Status: String, Sendable {
        case applied
        case alreadySatisfied = "already_satisfied"
        case rejectedBeforeWrite = "rejected_before_write"
        case attemptedUnverified = "attempted_unverified"
    }

    /// Only this adapter can construct an inverse; a caller's JSON/status cannot grant ownership.
    /// Retains the actual registry/cache, rather than importing authority into a different session.
    struct OwnedInverse: Sendable {
        fileprivate let project: TargetReference
        fileprivate let target: TargetReference
        fileprivate let before: String
        fileprivate let written: String
        fileprivate let registry: TargetRegistry
        fileprivate let cache: StateCache
        fileprivate let mirror: CoupledMirror?
    }

    struct Receipt: Sendable {
        let status: Status
        let before: String?
        let after: String?
        let survivingReference: TargetReference?
        let inverse: OwnedInverse?
        let result: CallTool.Result
    }

    static func operationPermitted() -> Bool {
        guard !Task.isCancelled else { return false }
        if let context = OperationTraceContext.current {
            guard !context.cancellationRequested(), context.ownsGate() else { return false }
            if let deadline = context.deadline, ContinuousClock.now >= deadline { return false }
        }
        return true
    }

    static func apply(
        _ action: Action, router: ChannelRouter, cache: StateCache, registry: TargetRegistry,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?
    ) async -> Receipt {
        await applyChecked(action, router: router, cache: cache, registry: registry,
            liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: nil)
    }

    /// One producer-observed track/strip pair. This is additive local coupling
    /// qualification, not the canonical planner's complete preservation footprint.
    /// A decoded report, equal names or matching ordinals cannot supply the pair.
    static func applyCoupled(
        _ action: Action, capture: SessionPopulationObservation.Capture,
        router: ChannelRouter, cache: StateCache, registry: TargetRegistry,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?
    ) async -> Receipt {
        func reject() -> Receipt {
            .init(status: .rejectedBeforeWrite, before: nil, after: nil, survivingReference: nil, inverse: nil,
                result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
        }
        guard capture.before == capture.after, capture.referencesEnabled, !capture.referencesStale,
              let fresh = capture.freshPopulation, fresh.stable, fresh.uiEffects.restoration == "restored",
              let snapshot = capture.targetSnapshot, await registry.currentSnapshot == snapshot,
              case .issued(let project)? = capture.projectIssuance, project == action.projectReference,
              let target = await registry.resolve(action.targetReference), let source = target.physicalTrack,
              target.kind == .track else { return reject() }
        let pairs = fresh.selectionAssociations.filter { $0.track.matches(source) }
        guard pairs.count == 1, let pair = pairs.first,
              fresh.selectionAssociations.filter({ $0.strip.matches(pair.strip) }).count == 1,
              capture.tracks.filter({ $0.physicalBinding?.matches(source) == true }).count == 1 else { return reject() }
        let rows = capture.channelStrips.indices.filter { capture.channelStrips[$0].physicalBinding?.matches(pair.strip) == true }
        guard rows.count == 1, let row = rows.first, let stripRef = capture.mixerReference(at: row),
              capture.channelStrips[row].name?.utf8.elementsEqual(action.expectedBefore.utf8) == true else { return reject() }
        let mirror = CoupledMirror(pair: pair, reference: stripRef, snapshot: snapshot,
            preservedTracks: capture.tracks.filter { $0.physicalBinding?.matches(pair.track) != true },
            preservedStrips: capture.channelStrips.filter { $0.physicalBinding?.matches(pair.strip) != true })
        return await applyChecked(action, router: router, cache: cache, registry: registry,
            liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: mirror)
    }

    fileprivate struct CoupledMirror: Sendable {
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let reference: TargetReference
        let snapshot: TargetRegistrySnapshot
        // Only names on already observed physical peers. This is not a new
        // population scan or a claim about hidden/unobserved host effects.
        var preservedTracks: [TrackState] = []
        var preservedStrips: [ChannelStripState] = []

        private func peerNamesStillHeld() -> Bool {
            for row in preservedTracks {
                guard operationPermitted(), let source = row.physicalBinding,
                      source.document.utf8.elementsEqual(pair.track.document.utf8),
                      CFEqual(source.window, pair.track.window), let index = source.currentIndex(),
                      case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                        from: source.header, runtime: source.runtime.ax),
                      name.utf8.elementsEqual(row.name.utf8), source.currentIndex() == index else { return false }
            }
            for row in preservedStrips {
                guard operationPermitted(), let source = row.physicalBinding, let expected = row.name,
                      source.document.utf8.elementsEqual(pair.strip.document.utf8),
                      CFEqual(source.window, pair.strip.window), CFEqual(source.mixer, pair.strip.mixer),
                      let index = source.currentIndex(runtime: pair.track.runtime),
                      case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(
                        source.strip, runtime: pair.track.runtime.ax),
                      name.utf8.elementsEqual(expected.utf8),
                      source.currentIndex(runtime: pair.track.runtime) == index else { return false }
            }
            return operationPermitted()
        }

        func namesStillHeld(before: String, after: String? = nil) -> Bool {
            let guardHelp = AXHelpers.HelpReadGuard(allowHelpReads: false, stop: { !operationPermitted() })
            return AXHelpers.HelpReadGuard.$current.withValue(guardHelp) {
                func matches(_ name: String) -> Bool {
                    name.utf8.elementsEqual(before.utf8) || after.map { name.utf8.elementsEqual($0.utf8) } == true
                }
                guard operationPermitted(), peerNamesStillHeld(), pair.track.currentIndex() != nil,
                      pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
                      case .success(.some(let stripName)) = AXPluginInstanceIdentity.stripNameResult(pair.strip.strip,
                        runtime: pair.track.runtime.ax), matches(stripName),
                      case .success(.some(let trackName)) = AXValueExtractors.extractTrackNameResult(
                        from: pair.track.header, runtime: pair.track.runtime.ax), matches(trackName),
                      pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
                      pair.track.currentIndex() != nil, peerNamesStillHeld(), operationPermitted() else { return false }
                return true
            }
        }

        func isCurrent(name: String, project: TargetReference, target: TargetReference,
                       registry: TargetRegistry) async -> Bool {
            guard operationPermitted(), await registry.currentSnapshot == snapshot,
                  let projectBinding = await registry.resolveCurrentProject(project),
                  let path = projectBinding.descriptor.projectFilePath,
                  pair.strip.projectPath?.utf8.elementsEqual(path.utf8) == true,
                  pair.track.document.utf8.elementsEqual(pair.strip.document.utf8),
                  await registry.resolve(target)?.physicalTrack?.matches(pair.track) == true,
                  await registry.resolve(reference)?.physicalMixerStrip?.matches(pair.strip) == true else { return false }
            let read = namesStillHeld(before: name)
            guard read, await registry.currentSnapshot == snapshot,
                  await registry.resolveCurrentProject(project)?.descriptor == projectBinding.descriptor,
                  // Actor bookends cannot replace the later native pair read.
                  namesStillHeld(before: name), operationPermitted() else { return false }
            return true
        }
    }

    private static func applyChecked(
        _ action: Action, router: ChannelRouter, cache: StateCache, registry: TargetRegistry,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?, mirror: CoupledMirror?
    ) async -> Receipt {
        if let failure = TrackDispatcher.renameNameFailure(action.desiredAfter) {
            return Receipt(status: .rejectedBeforeWrite, before: nil, after: nil,
                           survivingReference: nil, inverse: nil, result: failure)
        }
        if let mirror, !(await mirror.isCurrent(name: action.expectedBefore, project: action.projectReference,
                                               target: action.targetReference, registry: registry)) {
            return .init(status: .rejectedBeforeWrite, before: nil, after: nil, survivingReference: nil, inverse: nil,
                result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
        }
        let prewrite: (@Sendable (Bool) -> Bool)?
        if let mirror {
            prewrite = { allowPreview in
                mirror.namesStillHeld(before: action.expectedBefore, after: allowPreview ? action.desiredAfter : nil)
            }
        } else { prewrite = nil }
        let result = await $coupledWriteBoundary.withValue(prewrite) {
            await TrackDispatcher.handle(
            command: "rename",
            params: ["project_ref": .string(action.projectReference.rawValue),
                     "target_ref": .string(action.targetReference.rawValue),
                     "expected_name": .string(action.expectedBefore), "name": .string(action.desiredAfter)],
            router: router, cache: cache, targetRegistry: registry,
            liveTrackName: liveTrackName, liveTrackNames: liveTrackNames
            )
        }
        let body = decodedJSONObject(sharedText(result))
        let before = body?["before"] as? String
        let after = body?["observed"] as? String
        let rejected = body?["state"] as? String == "C" && body?["write_attempted"] as? Bool == false
        func unverified() -> Receipt {
            let response: CallTool.Result
            if body?["state"] as? String == "A" {
                // The writer's earlier observation is not this adapter's later
                // custody proof. Retain actual effects without claiming current A.
                var extras = body ?? [:]
                for key in ["state", "verified", "reason", "error"] { extras.removeValue(forKey: key) }
                extras["hint"] = "The writer completed, but the adapter could not retain the exact-source proof. Reread before another action."
                response = toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras), isError: true)
            } else {
                response = result
            }
            return Receipt(status: rejected ? .rejectedBeforeWrite : .attemptedUnverified,
                           before: before, after: after, survivingReference: nil, inverse: nil, result: response)
        }
        guard body?["state"] as? String == "A", body?["verified"] as? Bool == true,
              let before, before.utf8.elementsEqual(action.expectedBefore.utf8),
              let after, after.utf8.elementsEqual(action.desiredAfter.utf8),
              let binding = await registry.resolve(action.targetReference), binding.kind == .track,
              binding.descriptor.trackName.utf8.elementsEqual(after.utf8),
              await registry.resolveCurrentProject(action.projectReference) != nil, operationPermitted() else {
            return unverified()
        }
        let wrote = body?["write_attempted"] as? Bool == true
        let noOp = body?["via"] as? String == "no-op" && body?["write_attempted"] as? Bool == false
        guard wrote || noOp else {
            return unverified()
        }
        // A committed writer/rebound descriptor is historical evidence. Before
        // granting an inverse, corroborate the retained physical header again;
        // a same-name replacement or a newer edit is not our written state.
        if let source = binding.physicalTrack {
            guard source.currentIndex() != nil,
                  case .success(.some(let currentName)) = AXValueExtractors.extractTrackNameResult(
                    from: source.header, runtime: source.runtime.ax),
                  currentName.utf8.elementsEqual(after.utf8),
                  source.currentIndex() != nil else { return unverified() }
        }
        if let mirror, !(await mirror.isCurrent(name: after, project: action.projectReference,
                                               target: action.targetReference, registry: registry)) { return unverified() }
        let inverse = wrote ? OwnedInverse(project: action.projectReference, target: action.targetReference,
                                          before: before, written: after, registry: registry, cache: cache, mirror: mirror) : nil
        return Receipt(status: wrote ? .applied : .alreadySatisfied, before: before, after: after,
                       survivingReference: action.targetReference, inverse: inverse, result: result)
    }

    static func inverse(
        _ proof: OwnedInverse, router: ChannelRouter,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?
    ) async -> Receipt {
        // The owned inverse restores only this pair. A later peer rename is
        // neither ours to restore nor permission to overwrite it. Retain the
        // original pair/reference proof, without requiring peers' old names.
        var mirror = proof.mirror
        mirror?.preservedTracks = []
        mirror?.preservedStrips = []
        return await applyChecked(Action(projectReference: proof.project, targetReference: proof.target,
                           expectedBefore: proof.written, desiredAfter: proof.before),
                    router: router, cache: proof.cache, registry: proof.registry,
                    liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: mirror)
    }

    private static func sharedText(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }
}
