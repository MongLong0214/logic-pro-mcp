import Foundation
import MCP

/// PRD-007 (ADR-002 #285) — the index-binding ratchet's enforcement point.
///
/// ## What this defends
///
/// A track index is an ORDINAL, not an identity. Between the moment a caller
/// reads `logic://tracks` and the moment its write lands, a user drag, a track
/// creation, or a folder collapse can shift every row down one — and the write
/// then destroys a track the caller never named, reporting State A. The ref path
/// (`target_ref`) closes this by binding to a session-stable identity, but it is
/// opt-in and flag-gated, so the bare-index path stayed wide open on ops where
/// the mistake is unrecoverable.
///
/// This guard NARROWS that window for `.corroborated` ops — to the interval
/// between the live-header read and the write itself — by demanding the caller
/// state WHAT they believe sits at the index (`expected_name`), then proving it
/// against the LIVE surface before any write is attempted. It is a pre-write
/// proof, NOT atomic with the write: a reorder that lands inside the
/// guard-to-write interval can still write to the wrong track. Only `target_ref`
/// (and the future `.refRequired` tier) bind an identity across the write and
/// close the window entirely; corroboration is the best a bare index can do.
///
/// ## Why the uniqueness check is not optional
///
/// Matching `expected_name` at the index looks sufficient and is not. Two tracks
/// sharing a name can swap positions and leave `(index, name)` self-consistent
/// at BOTH ordinals — corroboration passes while the write lands on the wrong
/// one. So a non-unique match is refused outright and the caller is pushed to
/// `target_ref`, the only binding a swap cannot fool.
///
/// ## Invariants
///
/// - Runs ONLY on the index path. When `target_ref` is supplied the ref
///   machinery runs instead — never both (see `Outcome.reject` on the combo).
/// - Reads the LIVE header scan, never `StateCache`: the cache lags an
///   out-of-band reorder by the poll interval, which is precisely the window
///   being defended. Verifying against it would be theatre.
/// - Every failure is PRE-write: `write_attempted:false` is a fact here, not a
///   claim, because the guard returns before the dispatcher routes anything.
/// - Unreadable is never agreement: a nil scan fails closed.
enum IndexBindingGuard {
    /// The corroboration param. Single source; see
    /// `OperationRegistry.corroborationParam` for why it is not `name`.
    static let expectedNameParam = OperationRegistry.corroborationParam

    /// Reject `expected_name` + `target_ref` in the same call.
    ///
    /// MUST be called BEFORE `target_ref` resolution: a stale/unavailable ref
    /// otherwise fails first and reports `stale_target_reference` /
    /// `target_ref_unavailable`, hiding the caller's real mistake (they sent two
    /// competing bindings) behind a diagnosis of the one they shouldn't fix.
    ///
    /// Documented choice (PRD-007): reject rather than cross-check the two for
    /// agreement. The ref path already proves live identity and uniqueness (F5),
    /// so cross-checking would stack a second proof with a second error
    /// vocabulary over one failure. Exactly one binding wins per call.
    static func conflictingBindingFailure(
        policy: IndexBindingPolicy?,
        operation: String,
        params: [String: Value]
    ) -> CallTool.Result? {
        guard policy == .corroborated,
              params["target_ref"] != nil,
              trimmedNonEmpty(params[expectedNameParam]?.stringValue) != nil else { return nil }
        return toolInvalidParamsResult(
            "\(expectedNameParam) cannot be combined with target_ref — supply exactly one binding: target_ref (stable identity) or \(expectedNameParam) (index corroboration)",
            extras: [
                "operation": operation,
                "write_attempted": false,
                "safe_to_retry": true,
            ]
        )
    }

    /// Evaluate the binding proof for an index-path write.
    ///
    /// Takes the `policy` directly rather than looking it up from an
    /// `OperationID` so the `.refRequired` tier is testable via a synthetic spec
    /// while no production op carries it yet.
    ///
    /// - Returns: `nil` when the write may proceed; otherwise the fail-closed
    ///   State C result the dispatcher must return verbatim.
    static func evaluate(
        policy: IndexBindingPolicy?,
        operation: String,
        params: [String: Value],
        index: Int,
        liveTrackNames: (@Sendable () -> [Int: String]?)?
    ) -> CallTool.Result? {
        // The ref path owns this call and carries its own live-identity and
        // ambiguity guards (F5) — no second stack. The illegal combination was
        // already rejected pre-resolution by `conflictingBindingFailure`.
        if params["target_ref"] != nil { return nil }

        let expectedName = trimmedNonEmpty(params[expectedNameParam]?.stringValue)

        switch policy {
        case .none, .some(.legacyIndexAllowed):
            return nil

        case .some(.refRequired):
            return toolStateCResult(
                .stableTargetRequired,
                hint: "\(operation) accepts only a stable target_ref — a bare index cannot be bound to a track identity for this operation",
                extras: [
                    "operation": operation,
                    "requested_index": index,
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]
            )

        case .some(.corroborated):
            guard let expectedName else {
                return toolStateCResult(
                    .indexBindingCorroborationRequired,
                    hint: "\(operation) will not write to a bare index: supply \(expectedNameParam) (the track name you expect at index \(index)) so the target can be corroborated against the live surface, or supply target_ref to bind by stable identity instead",
                    extras: [
                        "operation": operation,
                        "requested_index": index,
                        "what_was_attempted": "bind \(operation) to index \(index)",
                        "what_was_observed": "no \(expectedNameParam) and no target_ref — the index is an unproven ordinal",
                        "write_attempted": false,
                        "safe_to_retry": true,
                    ]
                )
            }
            return corroborate(
                operation: operation,
                index: index,
                expectedName: expectedName,
                liveTrackNames: liveTrackNames
            )
        }
    }

    /// Prove `expectedName` identifies the live track at `index`, uniquely.
    private static func corroborate(
        operation: String,
        index: Int,
        expectedName: String,
        liveTrackNames: (@Sendable () -> [Int: String]?)?
    ) -> CallTool.Result? {
        // A nil probe is an UNREADABLE surface, not an absent check: the
        // deterministic test path leaves it nil by default, and a corroborated
        // op must never be talked into writing by the mere absence of evidence.
        guard let scanned = liveTrackNames?() else {
            return identityMismatchResult(
                operation: operation,
                index: index,
                expectedName: expectedName,
                observedName: nil,
                reason: "header_unreadable"
            )
        }

        let names = scanned.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let live = names[index], live == expectedName else {
            return identityMismatchResult(
                operation: operation,
                index: index,
                expectedName: expectedName,
                observedName: names[index],
                reason: names[index] == nil ? "header_unreadable" : "name_mismatch"
            )
        }

        let sameNameIndices = names.filter { $0.value == expectedName }.keys.sorted()
        guard sameNameIndices.count == 1 else {
            return toolStateCResult(
                .targetNameAmbiguous,
                hint: "\(operation) refused: '\(expectedName)' names \(sameNameIndices.count) live tracks, so matching it at index \(index) does not prove which one this is (same-named tracks can swap and stay self-consistent) — supply target_ref to bind by stable identity",
                extras: [
                    "operation": operation,
                    "requested_index": index,
                    "expected_track_name": expectedName,
                    "ambiguous_track_indices": sameNameIndices,
                    "what_was_attempted": "corroborate index \(index) against \(expectedNameParam) '\(expectedName)'",
                    "what_was_observed": "live track name '\(expectedName)' appeared at indices \(sameNameIndices.map(String.init).joined(separator: ", "))",
                    "write_attempted": false,
                    "safe_to_retry": false,
                ]
            )
        }
        return nil
    }

    /// Fail-closed State C for a corroboration that did not hold. Carries the
    /// same evidence keys the F1/F5 wrong-target guards emit
    /// (`expected_track_name` / `observed_track_name` / `what_was_attempted` /
    /// `what_was_observed`) so all three report a uniform shape.
    private static func identityMismatchResult(
        operation: String,
        index: Int,
        expectedName: String,
        observedName: String?,
        reason: String
    ) -> CallTool.Result {
        toolStateCResult(
            .targetIdentityMismatch,
            hint: observedName == nil
                ? "\(operation) refused: the live track header at index \(index) could not be read, so \(expectedNameParam) '\(expectedName)' could not be corroborated — an unreadable surface is never treated as agreement"
                : "\(operation) refused: index \(index) is live track '\(observedName!)', not \(expectedNameParam) '\(expectedName)' — the ordinal moved (out-of-band reorder); re-read logic://tracks, or supply target_ref to bind by stable identity",
            extras: [
                "operation": operation,
                "requested_index": index,
                "reason": reason,
                "expected_track_name": expectedName,
                "observed_track_name": observedName as Any? ?? NSNull(),
                "what_was_attempted": "corroborate index \(index) against \(expectedNameParam) '\(expectedName)' before writing",
                "what_was_observed": observedName.map { "index \(index) live track name is '\($0)'" }
                    ?? "index \(index) live track name was unreadable",
                "write_attempted": false,
                // Retrying the same (index, expected_name) reproduces the same
                // refusal — the caller must re-read or re-bind first, so this is
                // not a transient failure to hammer.
                "safe_to_retry": false,
            ]
        )
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
