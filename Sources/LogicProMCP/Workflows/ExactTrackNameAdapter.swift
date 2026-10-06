import Foundation
import MCP

/// #968 N1: one exact-local Arrange name action, not a coupled naming plan executor.
/// The canonical repair planner's preservation-footprint blocker remains authoritative.
enum ExactTrackNameAdapter {
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
        if let failure = TrackDispatcher.renameNameFailure(action.desiredAfter) {
            return Receipt(status: .rejectedBeforeWrite, before: nil, after: nil,
                           survivingReference: nil, inverse: nil, result: failure)
        }
        let result = await TrackDispatcher.handle(
            command: "rename",
            params: ["project_ref": .string(action.projectReference.rawValue),
                     "target_ref": .string(action.targetReference.rawValue),
                     "expected_name": .string(action.expectedBefore), "name": .string(action.desiredAfter)],
            router: router, cache: cache, targetRegistry: registry,
            liveTrackName: liveTrackName, liveTrackNames: liveTrackNames
        )
        let body = decodedJSONObject(sharedText(result))
        let before = body?["before"] as? String
        let after = body?["observed"] as? String
        let rejected = body?["state"] as? String == "C" && body?["write_attempted"] as? Bool == false
        guard body?["state"] as? String == "A", body?["verified"] as? Bool == true,
              let before, before.utf8.elementsEqual(action.expectedBefore.utf8),
              let after, after.utf8.elementsEqual(action.desiredAfter.utf8),
              let binding = await registry.resolve(action.targetReference), binding.kind == .track,
              binding.descriptor.trackName.utf8.elementsEqual(after.utf8),
              await registry.resolveCurrentProject(action.projectReference) != nil, operationPermitted() else {
            return Receipt(status: rejected ? .rejectedBeforeWrite : .attemptedUnverified,
                           before: before, after: after, survivingReference: nil, inverse: nil, result: result)
        }
        let wrote = body?["write_attempted"] as? Bool == true
        let noOp = body?["via"] as? String == "no-op" && body?["write_attempted"] as? Bool == false
        guard wrote || noOp else {
            return Receipt(status: .attemptedUnverified, before: before, after: after,
                           survivingReference: nil, inverse: nil, result: result)
        }
        let inverse = wrote ? OwnedInverse(project: action.projectReference, target: action.targetReference,
                                          before: before, written: after, registry: registry, cache: cache) : nil
        return Receipt(status: wrote ? .applied : .alreadySatisfied, before: before, after: after,
                       survivingReference: action.targetReference, inverse: inverse, result: result)
    }

    static func inverse(
        _ proof: OwnedInverse, router: ChannelRouter,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?
    ) async -> Receipt {
        await apply(Action(projectReference: proof.project, targetReference: proof.target,
                           expectedBefore: proof.written, desiredAfter: proof.before),
                    router: router, cache: proof.cache, registry: proof.registry,
                    liveTrackName: liveTrackName, liveTrackNames: liveTrackNames)
    }

    private static func sharedText(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }
}
