import Foundation
import MCP

/// ADR-002 (#285, part of #308): shared session-stable `target_ref` → track
/// index resolver for track / mixer / plugin mutations.
///
/// Extracted verbatim from `logic_tracks rename`'s original inline logic so that
/// every index-keyed mutation can ALSO accept an opaque `trk_…` reference behind
/// `FeatureFlags.adr002TargetRef`. Supplying `target_ref` while resolution is
/// unavailable fails closed; omitting it preserves the explicit-index path.
enum TargetRefResolver {
    /// A resolved mutation target: the concrete track index plus — when the
    /// caller supplied a valid `target_ref` — the reference that produced it, so
    /// the dispatcher can echo `target_ref` evidence on verified success.
    struct Resolved: Sendable {
        let index: Int
        let reference: TargetReference?
    }

    /// Resolution outcome. A dedicated enum (rather than `Swift.Result`) because
    /// the failure payload is a `CallTool.Result` envelope, which is not an
    /// `Error`. `.failure` carries the fully-formed fail-closed tool result the
    /// dispatcher returns verbatim.
    enum Outcome {
        case success(Resolved)
        case failure(CallTool.Result)
    }

    /// Resolve the target track index for a mutation.
    ///
    /// `target_ref` present:
    ///   0. Require the feature flag and a live resolver; otherwise fail closed.
    ///   1. Trim the raw reference; require non-empty + a live `TargetRegistry`.
    ///   2. `resolve` it and require `binding.kind == requiredKind`.
    ///   3. Optional cross-check: if an explicit index alias (`indexKeys`) is
    ///      ALSO present it must be ≥ 0 and equal the bound track index.
    ///   4. Drift check: the live cache must still hold a track at the bound
    ///      index whose fingerprint matches the one observed at bind time.
    ///   Resolution and drift failures after the availability gate fail closed
    ///   with `staleTargetReferenceResult` — never a wrong-target mutation.
    ///
    /// No `target_ref`: require an explicit non-negative index from `indexKeys`;
    /// on missing/malformed/negative return the caller's own `invalidIndexResult`
    /// (an autoclosure, so it is only built when actually needed).
    static func resolveMutationIndex(
        _ params: [String: Value],
        targetRegistry: TargetRegistry?,
        cache: StateCache,
        operation: String,
        indexKeys: [String] = ["index", "track"],
        requiredKind: TargetKind = .track,
        invalidIndexResult: @autoclosure () -> CallTool.Result
    ) async -> Outcome {
        if params["target_ref"] != nil {
            let rawReference = params["target_ref"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard FeatureFlags.adr002TargetRef, let targetRegistry else {
                return .failure(targetReferenceUnavailableResult(rawReference, operation: operation))
            }
            guard let rawReference,
                  !rawReference.isEmpty,
                  let binding = await targetRegistry.resolve(TargetReference(rawValue: rawReference)),
                  binding.kind == requiredKind
            else {
                return .failure(staleTargetReferenceResult(rawReference, operation: operation))
            }

            if indexKeys.contains(where: { params[$0] != nil }) {
                guard let requestedIndex = intParamOrNil(params, keys: indexKeys),
                      requestedIndex >= 0,
                      requestedIndex == binding.descriptor.trackIndex
                else {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
                }
            }

            let tracks = await cache.getTracks()
            guard let track = tracks.first(where: { $0.id == binding.descriptor.trackIndex }),
                  TargetDescriptor(trackIndex: track.id, trackName: track.name).fingerprint
                    == binding.observedFingerprint
            else {
                return .failure(staleTargetReferenceResult(rawReference, operation: operation))
            }
            return .success(Resolved(index: binding.descriptor.trackIndex, reference: binding.reference))
        }

        guard let requestedIndex = intParamOrNil(params, keys: indexKeys), requestedIndex >= 0 else {
            return .failure(invalidIndexResult())
        }
        return .success(Resolved(index: requestedIndex, reference: nil))
    }

    /// Echo the causal reference only on a verified State A response. A nil
    /// reference is the explicit-index/no-`target_ref` path and leaves the result unchanged.
    /// `legacyTrackRefAlias` additionally emits the pre-uniform `track_ref` key —
    /// rename shipped that echo first, so it keeps the alias for backward
    /// compatibility (G8); new consumers should read `target_ref`.
    static func addEvidence(
        _ reference: TargetReference?,
        to result: CallTool.Result,
        legacyTrackRefAlias: Bool = false
    ) -> CallTool.Result {
        guard let reference,
              case .text(let rawJSON, let annotations, let meta) = result.content.first,
              decodedJSONObject(rawJSON)?["state"] as? String == "A" else {
            return result
        }

        var evidence: [String: Any] = ["target_ref": reference.rawValue]
        if legacyTrackRefAlias {
            evidence["track_ref"] = reference.rawValue
        }
        let echoed = HonestContract.addExtras(
            evidence,
            into: rawJSON
        )
        guard echoed != rawJSON else { return result }

        var content = result.content
        content[0] = .text(text: echoed, annotations: annotations, _meta: meta)
        return CallTool.Result(
            content: content,
            structuredContent: structuredContentValue(fromToolText: echoed),
            isError: result.isError,
            _meta: result._meta
        )
    }

    /// Fail-closed State C for a `target_ref` that is missing/malformed, no longer
    /// in the registry (session / project-epoch / topology drift), a wrong-kind
    /// binding, or that no longer identifies the requested current track. Mirrors
    /// the exact shape `logic_tracks rename` has always emitted, with `operation`
    /// parameterised so each surface reports its own op.
    static func staleTargetReferenceResult(_ rawReference: String?, operation: String) -> CallTool.Result {
        toolStateCResult(
            .staleTargetReference,
            hint: "target_ref is stale or does not identify the requested current track",
            extras: [
                "operation": operation,
                "target_ref": rawReference ?? "",
            ]
        )
    }

    static func targetReferenceUnavailableResult(
        _ rawReference: String?,
        operation: String
    ) -> CallTool.Result {
        toolStateCResult(
            .targetRefUnavailable,
            hint: "stable target reference requires LOGIC_MCP_ADR002_TARGET_REF=1 and an active target resolver",
            extras: [
                "operation": operation,
                "target_ref": rawReference ?? "",
                "write_attempted": false,
            ]
        )
    }
}
