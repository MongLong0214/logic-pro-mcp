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
        let binding: TargetBinding?
    }

    /// Resolution outcome. A dedicated enum (rather than `Swift.Result`) because
    /// the failure payload is a `CallTool.Result` envelope, which is not an
    /// `Error`. `.failure` carries the fully-formed fail-closed tool result the
    /// dispatcher returns verbatim.
    enum Outcome {
        case success(Resolved)
        case failure(CallTool.Result)
    }

    static func validateProjectReference(
        _ params: [String: Value],
        targetRegistry: TargetRegistry?,
        operation: String
    ) async -> CallTool.Result? {
        guard let value = params["project_ref"] else { return nil }
        let rawReference = value.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard FeatureFlags.adr002TargetRef, let targetRegistry else {
            return projectReferenceUnavailableResult(rawReference, operation: operation)
        }
        guard let rawReference,
              !rawReference.isEmpty,
              await targetRegistry.resolveCurrentProject(TargetReference(rawValue: rawReference)) != nil else {
            return staleProjectReferenceResult(rawReference, operation: operation)
        }
        return nil
    }

    /// Resolve the target track index for a mutation.
    ///
    /// `target_ref` present:
    ///   0. Require the feature flag and a live resolver; otherwise fail closed.
    ///   1. Trim the raw reference; require non-empty + a live `TargetRegistry`.
    ///   2. `resolve` it and require `binding.kind` to be one of
    ///      `acceptedKinds` (or exactly `requiredKind` when omitted).
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
        invalidIndexResult: @autoclosure () -> CallTool.Result,
        acceptedKinds: [TargetKind]? = nil,
        liveTrackName: (@Sendable (Int) -> String?)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil,
        beforeFinalValidation: (@Sendable () async -> Void)? = nil
    ) async -> Outcome {
        if let projectFailure = await validateProjectReference(
            params,
            targetRegistry: targetRegistry,
            operation: operation
        ) {
            return .failure(projectFailure)
        }
        if params["target_ref"] != nil {
            let rawReference = params["target_ref"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowedKinds = acceptedKinds ?? [requiredKind]
            guard FeatureFlags.adr002TargetRef, let targetRegistry else {
                return .failure(targetReferenceUnavailableResult(rawReference, operation: operation))
            }
            guard let rawReference,
                  !rawReference.isEmpty,
                  let binding = await targetRegistry.resolve(TargetReference(rawValue: rawReference)),
                  allowedKinds.contains(binding.kind),
                  bindingFingerprintMatches(binding)
            else {
                return .failure(staleTargetReferenceResult(rawReference, operation: operation))
            }

            if binding.kind == .mixerStrip {
                let project = await cache.getProject()
                guard let physical = binding.physicalMixerStrip,
                      let projectPath = project.filePath,
                      physical.projectPath?.utf8.elementsEqual(projectPath.utf8) == true,
                      !indexKeys.contains(where: { params[$0] != nil }),
                      await cache.getChannelStrips().contains(where: { $0.physicalBinding?.matches(physical) == true }) else {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
                }
                await beforeFinalValidation?()
                guard !Task.isCancelled, await targetRegistry.resolve(binding.reference) != nil else {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
                }
                let currentProject = await cache.getProject()
                guard currentProject.filePath?.utf8.elementsEqual(projectPath.utf8) == true else {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
                }
                if let failure = await validateProjectReference(params, targetRegistry: targetRegistry, operation: operation) {
                    return .failure(failure)
                }
                // The writer revalidates this physical owner/membership at each action. An
                // Arrange index/name is deliberately not part of this resolution.
                return .success(.init(index: binding.descriptor.trackIndex, reference: binding.reference, binding: binding))
            }

            if let physical = binding.physicalTrack, operation == "track.rename" {
                guard let index = physical.currentIndex() else {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation,
                        hint: "The retained track is no longer in its issued project/window"))
                }
                if indexKeys.contains(where: { params[$0] != nil }),
                   intParamOrNil(params, keys: indexKeys) != index {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
                }
                let rows = await cache.getTracks().filter { $0.physicalBinding?.matches(physical) == true }
                guard rows.count == 1,
                      rows[0].name.utf8.elementsEqual(binding.descriptor.trackName.utf8),
                      case .success(let live?) = AXValueExtractors.extractTrackNameResult(
                        from: physical.header, runtime: physical.runtime.ax),
                      live.utf8.elementsEqual(binding.descriptor.trackName.utf8) else {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
                }
                await beforeFinalValidation?()
                guard await targetRegistry.resolve(binding.reference) != nil,
                      physical.currentIndex() == index,
                      await validateProjectReference(params, targetRegistry: targetRegistry, operation: operation) == nil else {
                    return .failure(staleTargetReferenceResult(rawReference, operation: operation))
                }
                return .success(Resolved(index: index, reference: binding.reference, binding: binding))
            }
            // Other writers retain their original ordinal/name semantics and every original
            // guard. Physical evidence adds corroboration, never new reorder/duplicate permission.
            if let physical = binding.physicalTrack,
               physical.currentIndex() != binding.descriptor.trackIndex {
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
                    .utf8.elementsEqual(binding.descriptor.fingerprint.utf8)
            else {
                return .failure(staleTargetReferenceResult(rawReference, operation: operation))
            }
            await beforeFinalValidation?()
            if let projectFailure = await validateProjectReference(
                params,
                targetRegistry: targetRegistry,
                operation: operation
            ) {
                return .failure(projectFailure)
            }
            guard await targetRegistry.resolve(binding.reference) != nil else {
                return .failure(staleTargetReferenceResult(rawReference, operation: operation))
            }
            // ADR-002 F5 — F1-equivalent mutation-boundary live track-identity
            // cross-check. The cache drift check above validates against the
            // state cache, which lags an out-of-band UI reorder by the poll
            // interval; this final check makes the LIVE AX header authoritative
            // over that possibly-stale cache before the write target is returned.
            // No-op when both live-track probes are nil (plugin / resolver-unit path) —
            // the explicit-index and flag-off paths never reach here at all.
            if let liveIdentityFailure = liveTrackIdentityGuard(
                binding: binding,
                rawReference: rawReference,
                operation: operation,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            ) {
                return .failure(liveIdentityFailure)
            }
            if let physical = binding.physicalTrack,
               physical.currentIndex() != binding.descriptor.trackIndex {
                return .failure(staleTargetReferenceResult(rawReference, operation: operation))
            }
            // ADR-005: a stable-reference resolution that survived every
            // continuity/fingerprint/live-identity guard is a traced phase.
            await OperationTraceContext.record(.targetResolved, attributes: [
                "target_ref": binding.reference.rawValue,
                "outcome": "resolved",
            ])
            return .success(Resolved(
                index: binding.descriptor.trackIndex,
                reference: binding.reference,
                binding: binding
            ))
        }

        guard let requestedIndex = intParamOrNil(params, keys: indexKeys), requestedIndex >= 0 else {
            return .failure(invalidIndexResult())
        }
        if let projectFailure = await validateProjectReference(
            params,
            targetRegistry: targetRegistry,
            operation: operation
        ) {
            return .failure(projectFailure)
        }
        return .success(Resolved(index: requestedIndex, reference: nil, binding: nil))
    }

    static func pluginInsertFingerprint(
        descriptor: TargetDescriptor,
        insert: Int,
        pluginIdentity: String?
    ) -> String {
        "\(descriptor.fingerprint)|insert=\(insert)|plugin=\(pluginIdentity ?? "")"
    }

    static func pluginInsertIndex(from fingerprint: String) -> Int? {
        TargetDescriptor.pluginInsertIndex(from: fingerprint)
    }

    /// Strip the exact length-aware descriptor prefix, not a delimiter found
    /// inside an arbitrary track name. The remainder is the originally observed
    /// occupied plugin identity (or the empty string for a verified empty slot).
    static func pluginInsertIdentity(from binding: TargetBinding) -> String? {
        guard binding.kind == .pluginInsert,
              let insert = binding.pluginInsertIndex,
              insert >= 0,
              pluginInsertIndex(from: binding.observedFingerprint) == insert else { return nil }
        let prefix = "\(binding.descriptor.fingerprint)|insert=\(insert)|plugin="
        guard binding.observedFingerprint.utf8.starts(with: prefix.utf8) else { return nil }
        return String(binding.observedFingerprint.dropFirst(prefix.count))
    }

    private static func bindingFingerprintMatches(_ binding: TargetBinding) -> Bool {
        let descriptorFingerprint = binding.descriptor.fingerprint
        switch binding.kind {
        case .project:
            return false
        case .track, .mixerStrip:
            return binding.observedFingerprint.utf8.elementsEqual(descriptorFingerprint.utf8)
        case .pluginInsert:
            return pluginInsertIdentity(from: binding) != nil
        }
    }

    /// Echo the causal reference only on a verified State A response. A nil
    /// reference is the explicit-index/no-`target_ref` path and leaves the result unchanged.
    /// `legacyTrackRefAlias` additionally emits the pre-uniform `track_ref` key —
    /// rename shipped that echo first, so it keeps the alias for backward
    /// compatibility (G8); new consumers should read `target_ref`.
    static func addEvidence(
        _ reference: TargetReference?,
        fingerprint: String? = nil,
        to result: CallTool.Result,
        legacyTrackRefAlias: Bool = false
    ) -> CallTool.Result {
        guard let reference,
              case .text(let rawJSON, let annotations, let meta) = result.content.first,
              decodedJSONObject(rawJSON)?["state"] as? String == "A" else {
            return result
        }

        var evidence: [String: Any] = ["target_ref": reference.rawValue]
        if let fingerprint {
            evidence["target_fingerprint"] = fingerprint
        }
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

    /// ADR-002 F5 — F1-equivalent live track-identity cross-check for
    /// `target_ref`-resolved track / mixer mutations. `liveTrackNames` scans all
    /// LIVE AX track headers and checks the bound index plus same-name indices;
    /// it is threaded down only by the track / mixer dispatchers (plugins carry the equivalent F1 guard
    /// inside their own AX write, and pass nil here). When nil this is a no-op,
    /// so the resolver stays AX-agnostic and the explicit-index path is
    /// unaffected. Requires the live header at the reference's bound index to
    /// still read back its bound raw track-name bytes, with no byte-identical
    /// name at any other index. A mismatch, ambiguity, or unreadable live name
    /// fails closed with `stale_target_reference`,
    /// `write_attempted:false`, and no write, making the live read authoritative
    /// over a state cache that may lag an out-of-band UI reorder.
    private static func liveTrackIdentityGuard(
        binding: TargetBinding,
        rawReference: String?,
        operation: String,
        liveTrackName: (@Sendable (Int) -> String?)?,
        liveTrackNames: (@Sendable () -> [Int: String]?)?
    ) -> CallTool.Result? {
        guard liveTrackName != nil || liveTrackNames != nil else { return nil }
        let index = binding.descriptor.trackIndex
        let expected = binding.descriptor.trackName
        guard let scanned = liveTrackNames?() else {
            let live = liveTrackName?(index)
            return staleLiveIdentityResult(
                rawReference,
                operation: operation,
                index: index,
                expected: binding.descriptor.trackName,
                observed: live
            )
        }
        let live = scanned[index]
        guard let live, live.utf8.elementsEqual(expected.utf8) else {
            return staleLiveIdentityResult(
                rawReference,
                operation: operation,
                index: index,
                expected: binding.descriptor.trackName,
                observed: live
            )
        }
        let ambiguousIndices = scanned
            .filter { $0.value.utf8.elementsEqual(expected.utf8) }
            .map(\.key)
            .sorted()
        guard ambiguousIndices.count <= 1 else {
            return staleLiveIdentityResult(
                rawReference,
                operation: operation,
                index: index,
                expected: binding.descriptor.trackName,
                observed: live,
                ambiguousIndices: ambiguousIndices
            )
        }
        return nil
    }

    /// Fail-closed State C for the F5 live-identity mismatch. Carries the same
    /// evidence fields F1 emits (`expected_track_name` / `observed_track_name` /
    /// `what_was_attempted` / `what_was_observed` / `safe_to_retry`) so the two
    /// wrong-target guards report a uniform shape.
    static func staleLiveIdentityResult(
        _ rawReference: String?,
        operation: String,
        index: Int,
        expected: String,
        observed: String?,
        ambiguousIndices: [Int] = []
    ) -> CallTool.Result {
        var extras: [String: Any] = [
            "operation": operation,
            "target_ref": rawReference ?? "",
            "expected_track_name": expected,
            "observed_track_name": observed as Any? ?? NSNull(),
            "what_was_attempted": "confirm the live track at index \(index) still matches the referenced track before writing",
            "what_was_observed": observed.map { "index \(index) live track name is '\($0)'" }
                ?? "index \(index) live track name was unreadable",
            "safe_to_retry": false,
            "write_attempted": false,
        ]
        if !ambiguousIndices.isEmpty {
            // Nothing is stale here and nothing was reordered: the reference still names the right
            // index and the right name, but that name is shared, so no evidence can say WHICH track
            // is meant. The field deliberately includes the bound index as well as every other
            // collision, matching the explicit-index corroboration path.
            extras["ambiguous_live_track_name"] = true
            extras["ambiguous_track_indices"] = ambiguousIndices
            extras["what_was_observed"] = "live track name '\(expected)' also appeared at indices \(ambiguousIndices.map(String.init).joined(separator: ", "))"
            return toolStateCResult(
                .ambiguousTargetName,
                hint: "'\(expected)' names more than one live track, so the target cannot be "
                    + "identified. Rename it with rename {name, index} — the index form is not "
                    + "blocked by name ambiguity — then retry with the new name.",
                extras: extras
            )
        }
        return toolStateCResult(
            .staleTargetReference,
            hint: "target_ref no longer names the live track at its bound index (out-of-band reorder)",
            extras: extras
        )
    }

    /// Fail-closed State C for a `target_ref` that is missing/malformed, no longer
    /// in the registry (session / project-epoch / topology drift), a wrong-kind
    /// binding, or that no longer identifies the requested current track. Mirrors
    /// the exact shape `logic_tracks rename` has always emitted, with `operation`
    /// parameterised so each surface reports its own op.
    static func staleTargetReferenceResult(
        _ rawReference: String?,
        operation: String,
        referenceKey: String = "target_ref",
        hint: String = "target_ref is stale or does not identify the requested current track",
        extras: [String: Any] = [:]
    ) -> CallTool.Result {
        toolStateCResult(
            .staleTargetReference,
            hint: hint,
            extras: extras.merging([
                "operation": operation,
                referenceKey: rawReference ?? "",
                "write_attempted": false,
            ]) { _, authoritative in authoritative }
        )
    }

    private static func staleProjectReferenceResult(
        _ rawReference: String?,
        operation: String
    ) -> CallTool.Result {
        staleTargetReferenceResult(
            rawReference,
            operation: operation,
            referenceKey: "project_ref",
            hint: "project_ref is stale or does not identify the current project"
        )
    }

    static func targetReferenceUnavailableResult(
        _ rawReference: String?,
        operation: String
    ) -> CallTool.Result {
        toolStateCResult(
            .targetRefUnavailable,
            hint: "stable target reference requires an active target resolver and LOGIC_MCP_ADR002_TARGET_REF unset or != \"0\" (on by default)",
            extras: [
                "operation": operation,
                "target_ref": rawReference ?? "",
                "write_attempted": false,
            ]
        )
    }

    private static func projectReferenceUnavailableResult(
        _ rawReference: String?,
        operation: String
    ) -> CallTool.Result {
        toolStateCResult(
            .targetRefUnavailable,
            hint: "project_ref requires an active project identity and LOGIC_MCP_ADR002_TARGET_REF unset or != \"0\" (on by default)",
            extras: [
                "operation": operation,
                "project_ref": rawReference ?? "",
                "write_attempted": false,
            ]
        )
    }
}
