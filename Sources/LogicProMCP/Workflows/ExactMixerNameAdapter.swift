import Foundation
import MCP

/// One exact local physical-strip action, not a coupled naming-plan executor.
/// The existing planner's required preservation footprint remains authoritative.
enum ExactMixerNameAdapter {
    typealias Action = ExactTrackNameAdapter.Action
    typealias Status = ExactTrackNameAdapter.Status

    /// Only a verified action on this registry's original source grants an
    /// inverse. Neither caller JSON nor a different cache/channel imports it.
    struct OwnedInverse: Sendable {
        fileprivate let action: Action
        fileprivate let source: AXMixerStripBinding.Binding
        fileprivate let channel: AccessibilityChannel
        fileprivate let cache: StateCache
        fileprivate let registry: TargetRegistry
        fileprivate let runtime: AXLogicProElements.Runtime
    }

    struct Receipt: Sendable {
        let status: Status
        let before: String?
        let after: String?
        let survivingReference: TargetReference?
        let inverse: OwnedInverse?
        let rereadRequired: Bool
        let result: CallTool.Result
    }

    private static func rejected(_ result: CallTool.Result) -> Receipt {
        .init(status: .rejectedBeforeWrite, before: nil, after: nil,
              survivingReference: nil, inverse: nil, rereadRequired: false, result: result)
    }

    static func apply(
        _ action: Action, channel: AccessibilityChannel, cache: StateCache,
        registry: TargetRegistry, runtime: AXLogicProElements.Runtime
    ) async -> Receipt {
        if let failure = TrackDispatcher.renameNameFailure(action.desiredAfter) { return rejected(failure) }
        let operation = "mixer.rename_exact"
        let params: [String: Value] = ["project_ref": .string(action.projectReference.rawValue),
                                      "target_ref": .string(action.targetReference.rawValue)]
        let snapshot = await registry.currentSnapshot
        let resolved = await TargetRefResolver.resolveMutationIndex(params, targetRegistry: registry,
            cache: cache, operation: operation,
            invalidIndexResult: toolInvalidParamsResult("An issued physical Mixer reference is required"),
            acceptedKinds: [.mixerStrip])
        let binding: TargetBinding
        switch resolved {
        case .failure(let result): return rejected(result)
        case .success(let target):
            guard let value = target.binding else {
                return rejected(TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: operation))
            }
            binding = value
        }
        guard let source = binding.physicalMixerStrip,
              binding.descriptor.trackName.utf8.elementsEqual(action.expectedBefore.utf8),
              let project = await registry.resolveCurrentProject(action.projectReference),
              let path = project.descriptor.projectFilePath,
              source.projectPath?.utf8.elementsEqual(path.utf8) == true,
              await registry.currentSnapshot == snapshot,
              ExactTrackNameAdapter.operationPermitted() else {
            return rejected(TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: operation))
        }

        // The existing writer owns acquisition, exact expected bytes, paired
        // events and committed readback. No new actuator or public route.
        let result = await AXMixerStripBinding.$current.withValue(source) {
            await channel.execute(operation: operation, params: ["expected_name": action.expectedBefore, "name": action.desiredAfter])
        }
        let body = decodedJSONObject(result.message)
        let before = body?["before"] as? String
        let after = body?["observed"] as? String
        let wrote = body?["write_attempted"] as? Bool == true
        let noOp = body?["via"] as? String == "no-op" && body?["write_attempted"] as? Bool == false
        func unverified() -> Receipt {
            // A writer's earlier committed observation does not establish the
            // adapter's later reference/custody proof. Preserve observations,
            // but never expose that earlier A as current adapter success.
            let response: CallTool.Result
            if body?["state"] as? String == "A" {
                var extras = body ?? [:]
                for key in ["state", "verified", "reason", "error"] { extras.removeValue(forKey: key) }
                extras["hint"] = "The writer completed, but the adapter could not retain the exact-source proof. Reread before another action."
                response = toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras), isError: true)
            } else {
                response = toolTextResult(result)
            }
            return .init(status: body?["state"] as? String == "C" && body?["write_attempted"] as? Bool == false
                    ? .rejectedBeforeWrite : .attemptedUnverified,
                  before: before, after: after, survivingReference: nil, inverse: nil,
                  rereadRequired: true, result: response)
        }
        guard body?["state"] as? String == "A", body?["verified"] as? Bool == true,
              let before, before.utf8.elementsEqual(action.expectedBefore.utf8),
              let after, after.utf8.elementsEqual(action.desiredAfter.utf8), wrote || noOp else { return unverified() }

        func observedOrdinal() -> Int? {
            let help = AXHelpers.HelpReadGuard(allowHelpReads: false, stop: { !ExactTrackNameAdapter.operationPermitted() })
            return AXHelpers.HelpReadGuard.$current.withValue(help) {
                guard ExactTrackNameAdapter.operationPermitted(), let index = source.currentIndex(runtime: runtime),
                      case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(source.strip, runtime: runtime.ax),
                      name.utf8.elementsEqual(after.utf8), source.currentIndex(runtime: runtime) == index,
                      ExactTrackNameAdapter.operationPermitted() else { return nil }
                return index
            }
        }
        guard let index = observedOrdinal(), await registry.currentSnapshot == snapshot,
              let current = await registry.resolve(action.targetReference),
              current.physicalMixerStrip?.matches(source) == true,
              current.descriptor.trackName.utf8.elementsEqual(action.expectedBefore.utf8),
              await registry.resolveCurrentProject(action.projectReference)?.descriptor == project.descriptor,
              await cache.getProject().filePath?.utf8.elementsEqual(path.utf8) == true,
              await cache.getChannelStrips().filter({ $0.physicalBinding?.matches(source) == true }).count == 1,
              ExactTrackNameAdapter.operationPermitted() else { return unverified() }
        // Causal same-source proof, not a name/index identity bridge. A
        // historical cache population is left intact and must be reread.
        await registry.rebind(action.targetReference, to: .init(trackIndex: index, trackName: after))
        guard await registry.currentSnapshot == snapshot,
              let rebound = await registry.resolve(action.targetReference),
              rebound.physicalMixerStrip?.matches(source) == true,
              rebound.descriptor.trackName.utf8.elementsEqual(after.utf8),
              await registry.resolveCurrentProject(action.projectReference)?.descriptor == project.descriptor,
              observedOrdinal() != nil,
              // Membership revalidation does not read the name. A newer edit
              // during that read must not inherit the writer's earlier A.
              case .success(.some(let finalName)) = AXPluginInstanceIdentity.stripNameResult(source.strip, runtime: runtime.ax),
              finalName.utf8.elementsEqual(after.utf8),
              source.currentIndex(runtime: runtime) != nil,
              ExactTrackNameAdapter.operationPermitted() else { return unverified() }
        let inverse = wrote ? OwnedInverse(action: .init(projectReference: action.projectReference,
            targetReference: action.targetReference, expectedBefore: after, desiredAfter: before),
            source: source, channel: channel, cache: cache, registry: registry, runtime: runtime) : nil
        return .init(status: wrote ? .applied : .alreadySatisfied, before: before, after: after,
                     survivingReference: action.targetReference, inverse: inverse,
                     rereadRequired: wrote, result: toolTextResult(result))
    }

    static func inverse(_ proof: OwnedInverse) async -> Receipt {
        guard let binding = await proof.registry.resolve(proof.action.targetReference),
              binding.physicalMixerStrip?.matches(proof.source) == true else {
            return rejected(TargetRefResolver.staleTargetReferenceResult(proof.action.targetReference.rawValue,
                                                                         operation: "mixer.rename_exact"))
        }
        return await apply(proof.action, channel: proof.channel, cache: proof.cache,
                           registry: proof.registry, runtime: proof.runtime)
    }
}
