import Foundation

/// Honest Contract (v3.1.0+): every mutating operation returns one of three
/// states so that a client (LLM agent) can distinguish confirmed success,
/// uncertain success, and hard failure without heuristically parsing free-form
/// text. See `docs/API.md`.
///
/// This module is the single place responsible for producing the JSON that is
/// wrapped in `ChannelResult.success` / `.error`. Every new mutating op should
/// build its response through `encodeStateA` / `encodeStateB` / `encodeStateC`
/// to keep the wire format invariant.
enum HonestContract {

    /// Why a write is uncertain. Stable string enum so downstream tooling can
    /// switch on it.
    enum UncertainReason {
        /// MCU fader / V-Pot echo did not arrive inside the polling window.
        case echoTimeout(ms: Int)
        /// The AX read-back attribute is not exposed on this element (Logic
        /// build / state dependent).
        case readbackUnavailable
        /// Read-back succeeded but returned a different value than requested.
        case readbackMismatch
        /// Retry budget exhausted without either a confirmed read-back or a
        /// hard error.
        case retryExhausted
        /// `midi.import_file` created a new track, but the imported lane(s) are
        /// GM Device / external-MIDI synth lanes (NOT audible software-instrument
        /// tracks). The write landed and a region exists, but the import cannot be
        /// claimed audible-verified: such lanes route to a General MIDI device and
        /// may bounce silent. Downgrades State A → State B so a caller never treats
        /// a count-delta success as an audible arrangement. v3.6.x (#128).
        case importedAsGMDevice
        case sendOnlyNoReadback
        case sagaReconciliationRequired
        case sagaCancellationPending

        var rawValue: String {
            switch self {
            case .echoTimeout(let ms): return "echo_timeout_\(ms)ms"
            case .readbackUnavailable: return "readback_unavailable"
            case .readbackMismatch: return "readback_mismatch"
            case .retryExhausted: return "retry_exhausted"
            case .importedAsGMDevice: return "imported_as_gm_device"
            case .sendOnlyNoReadback: return "send_only_no_readback"
            case .sagaReconciliationRequired: return "saga_reconciliation_required"
            case .sagaCancellationPending: return "saga_cancellation_pending"
            }
        }
    }

    /// Hard-failure category. Stable string enum.
    enum FailureError: String {
        case axWriteFailed = "ax_write_failed"
        case elementNotFound = "element_not_found"
        case permissionDenied = "permission_denied"
        case systemEventsAutomationDenied = "system_events_automation_denied"
        case logicNotRunning = "logic_not_running"
        case invalidParams = "invalid_params"
        /// A consent-gated configuration write was requested without explicit
        /// consent, so nothing was touched (setup_arm_key, #413).
        case consentRequired = "consent_required"
        case readbackUnavailable = "readback_unavailable"
        case readbackMismatch = "readback_mismatch"
        /// Operation explicitly not implemented via this channel / build of
        /// Logic. Distinct from `.elementNotFound` (target absent) and
        /// `.axWriteFailed` (write attempt rejected): the surface itself does
        /// not exist. Terminal — no other channel can do better. v3.1.2 P2-1.
        case notImplemented = "not_implemented"
        /// The requested transport/port for a channel is not configured or
        /// available (e.g. CoreMIDI virtual port absent, KeyCmd not yet
        /// published). Terminal — falling back to another channel cannot
        /// recover the missing port. v3.1.6 T1 (PRD Issue#1 R7).
        case portUnavailable = "port_unavailable"
        /// The router walked the full channel chain for this operation and
        /// every channel reported `healthCheck.unavailable` (or its readiness
        /// gate failed). Terminal — the chain itself produced no usable
        /// candidate. Distinct from `.portUnavailable` (a specific channel's
        /// port is missing) and `.logicNotRunning` (a single channel's
        /// process gone): exhaustion is the chain-level aggregate signal.
        /// v3.4.5-rc5 (to fix semantic overload where
        /// every router fallthrough was being mis-classified as
        /// `port_unavailable` regardless of root cause).
        case channelsExhausted = "channels_exhausted"
        /// `midi.import_file` clicked File → Import → MIDI File but the
        /// file-open sheet never appeared inside the bounded poll window, so the
        /// path keystroke was never issued (no side effect). Distinct from
        /// `.axWriteFailed` (menu click rejected) and `.readbackMismatch` (import
        /// ran but created no track): the dialog itself was never observed, which
        /// is the textbook occluded/unhealthy-session signature. Terminal — a
        /// different channel cannot conjure the missing sheet. v3.6.x (#140).
        case dialogNotFound = "dialog_not_found"

        // HC v2 (logic_plugins.* verified plugin path) — §4 error table.
        case unsupportedMode = "unsupported_mode"
        case projectPathRequired = "project_path_required"
        case projectIdentityMismatch = "project_identity_mismatch"
        case unknownPluginIdentity = "unknown_plugin_identity"
        case unsupportedParamReadback = "unsupported_param_readback"
        case incompleteInventory = "incomplete_inventory"
        case targetPluginMismatch = "target_plugin_mismatch"
        /// A candidate editor had the requested track and parameter control, but
        /// its direct static-text header did not map to the requested canonical
        /// plug-in id. Refused before an AX value write.
        case pluginWindowPluginMismatch = "plugin_window_plugin_mismatch"
        /// The requested plug-in occupies multiple inserts and a matching
        /// header-proven editor was already visible before the target slot could
        /// establish provenance by opening one editor from a zero-editor state.
        case duplicatePluginEditorAlreadyOpen = "duplicate_plugin_editor_already_open"
        /// The requested plug-in occupies multiple inserts, but one target-slot
        /// open press did not leave exactly one header-proven matching editor.
        /// This includes a hidden sibling restored by the press.
        case duplicatePluginEditorCountMismatch = "duplicate_plugin_editor_count_mismatch"
        case slotOccupied = "slot_occupied"
        case trackSelectionFailed = "track_selection_failed"
        case staleSnapshot = "stale_snapshot"
        case staleTargetReference = "stale_target_reference"
        /// A binding still names the right index and the right name, but that name is not unique,
        /// so nothing can prove WHICH track is meant. `ambiguous_track_indices` always contains
        /// all live tracks carrying the colliding name, whether the binding came from `target_ref`
        /// or `expected_name`. Deliberately distinct from
        /// `.staleTargetReference`: nothing is stale and nothing was reordered, and reporting it as
        /// staleness sent callers looking for a reorder that never happened.
        case ambiguousTargetName = "ambiguous_target_name"
        case targetRefUnavailable = "target_ref_unavailable"

        // PRD-007 (ADR-002 #285) — index-binding ratchet. These describe the
        // INDEX path's binding proof and are deliberately NOT folded into
        // `.staleTargetReference`, which means something different and
        // narrower: a `target_ref` token that no longer resolves. Here no ref
        // exists at all, so reporting one as stale would send the caller
        // hunting a token they never held.
        //
        // CLASSIFICATION (CTO ruling, PRD-007 P2-5): these four are deliberately
        // NOT added to `terminalErrorCodes`. Every one is raised pre-route and
        // pre-write, and every one is caller-correctable in place — supply or fix
        // `expected_name` (or switch to `target_ref`) and retry. That is exactly
        // the retryable posture of `.targetRefUnavailable`, not a terminal
        // channel-exhaustion or unsupported-surface failure. Re-classifying to
        // terminal is a separate decision, warranted only if live soak shows
        // callers hammering an uncorrectable case; nothing here is uncorrectable.
        /// A `.corroborated` op was called with a bare index and no
        /// `expected_name` (and no `target_ref`), so the ordinal is unproven.
        /// Nothing was read or written — supplying either binding is a safe retry.
        case indexBindingCorroborationRequired = "index_binding_corroboration_required"
        /// The live header at the supplied index does not carry the
        /// `expected_name` the caller corroborated with — the ordinal moved
        /// under them — or the header could not be read at all
        /// (`reason: header_unreadable`), which is never read as agreement.
        /// Fail-closed pre-write: the wrong track was NOT touched.
        case targetIdentityMismatch = "target_identity_mismatch"
        /// A `.refRequired` op was called with a bare index. Unlike
        /// `.indexBindingCorroborationRequired`, no `expected_name` can rescue
        /// this — a stable `target_ref` is the only accepted binding.
        case stableTargetRequired = "stable_target_required"
        case windowOpenFailed = "window_open_failed"
        case windowIdentityUnresolved = "window_identity_unresolved"
        case paramControlNotFound = "param_control_not_found"
        case readbackLostAfterWrite = "readback_lost_after_write"
        /// An AXValue nudge was accepted but the readback did not establish
        /// reliable progress toward the requested target. This is distinct from
        /// `ax_write_failed`: the write may have been accepted.
        case incrementWalkNoProgress = "increment_walk_no_progress"
        /// The bounded AXValue-nudge loop reached its caller-owned cap without
        /// arriving. It is not an operation timeout: the explicit write budget
        /// is the fact a caller can change or diagnose.
        case incrementWalkBudgetExhausted = "increment_walk_budget_exhausted"
        /// The nudge loop crossed the target and then moved farther away on the
        /// same side, so continuing would no longer be trustworthy.
        case incrementWalkOvershot = "increment_walk_overshot"
        case postInsertPluginMismatch = "post_insert_plugin_mismatch"
        case postInsertReadbackUnavailable = "post_insert_readback_unavailable"
        /// `logic_plugins.insert_verified` reached its live-write boundary with
        /// every deterministic gate passed, but the actual AX insert is not
        /// performable in this Logic build: the exact slot popup path completed
        /// without the requested plugin appearing in the readback
        /// inventory. Honest-deferred terminal — no channel can do better in
        /// this verified path, so the op fails closed here rather than fabricating a State A.
        /// v3.5 T6. `set_param_verified` State A is unaffected.
        case insertNotAxAutomatable = "insert_not_ax_automatable"
        /// `logic_plugins.insert_verified` could not complete a TRANSIENT pre-mount
        /// setup step (the target slot popup was not clickable, the popup menu was
        /// not anchored to the target slot, or the exact plugin leaf was not found).
        /// No write was
        /// attempted; the caller can retry (`safe_to_retry:true`). Distinct from
        /// `insert_not_ax_automatable` (the exact popup selection committed but the plugin
        /// never mounted — permanent). v3.5 T6 (P2-3).
        case insertSetupFailed = "insert_setup_failed"
        /// `logic_plugins.insert_verified` mounted the requested plugin, but the
        /// post-insert readback observed it at a DIFFERENT slot than requested.
        /// Rather than confirm a slot it did not target (false State A), the op
        /// fails closed and reports `observed_slot`; the stray mount is rolled
        /// back. This is a defensive guard for Logic UI drift, not the expected
        /// success path. v3.5 T6.
        case insertLandedAtDifferentSlot = "insert_landed_at_different_slot"
        case rollbackFailed = "rollback_failed"
        case verifiedOpInProgress = "verified_op_in_progress"
        case mutatingOperationInProgress = "mutating_operation_in_progress"
        case operationTimeout = "operation_timeout"
        /// `track.set_instrument` could not stage the Logic Library panel: it
        /// was closed and the auto-open (⌘L / View > Show Library) did not make
        /// it appear before the bounded re-check. The patch was never attempted.
        /// Distinct from `.axWriteFailed` (a navigation write was rejected) and
        /// `.elementNotFound` (a specific row absent): the whole panel UI the
        /// op needs is not present. Recovery: open the Library (⌘L) in Logic
        /// Pro and retry. v3.6.x (#131/#135/#141 canonical hardening).
        case libraryPanelUnavailable = "library_panel_unavailable"
        /// `track.set_instrument` targeted a track whose channel-strip type
        /// cannot host a software-instrument patch (GM Device / External MIDI).
        /// Terminal for this op — loading a Library instrument patch onto an
        /// external-MIDI/GM-Device strip is not a supported operation. Recovery:
        /// target a Software Instrument track (or create one and copy the
        /// regions). v3.6.x (#131).
        case unsupportedTrackType = "unsupported_track_type"
        /// `track.set_instrument` pre-resolved the requested path against the
        /// cached Library inventory and the path does not exist. Terminal — the
        /// op is NOT attempted (no AX navigation), distinguishing a genuine
        /// "path does not exist" precondition from a transient "path exists but
        /// live AX nav failed" (which still surfaces as `.axWriteFailed`).
        /// Recovery: pick a path present in scan_library. v3.6.x (#135/#141).
        case pathNotInLibrary = "path_not_in_library"
        case folderNotPreset = "folder_not_preset"
        /// A server-side invariant was violated while processing a request. The
        /// result must fail closed without claiming an observed absence.
        case internalInconsistency = "internal_inconsistency"
        /// The requested operation cannot be performed in the front document's
        /// current state — e.g. `project.save` on an UNTITLED document that has
        /// no on-disk path. Firing `save front document` on such a document
        /// raises Logic's modal Save sheet and the AppleEvent blocks until it is
        /// dismissed, so the save path fails fast here instead. Terminal — no
        /// other channel can save an untitled document without a path; the
        /// caller must supply one via `project.save_as`. #144 (P3 hardening).
        case unsupportedState = "unsupported_state"
        /// A command token the dispatcher recognises but that is deliberately
        /// NOT part of the production MCP contract (no deterministic / verified
        /// path exists yet). Distinct from `.notImplemented` (a surface that does
        /// not exist at all): these are catalogued not-exposed stubs, excluded
        /// from the workflow census, so a complete-surface harness can classify
        /// the response as expected rather than a malfunction. Terminal. #202.
        case commandNotExposed = "command_not_exposed"
        case indexOutOfRange = "index_out_of_range"
        /// A `logic_system.help` category token that is not one of the known
        /// dispatcher categories. Distinct from `.invalidParams` so a client
        /// can tell a typo'd category apart from a missing required argument,
        /// and so an unknown category never silently returns full help. #219.
        case unknownCategory = "unknown_category"
        /// A REGISTERED command reached a dispatcher without a matching
        /// switch case — registry↔dispatch drift. Unregistered commands are
        /// rejected at the server layer and never produce this; the
        /// executable dispatch census asserts it never fires for any
        /// registered operation.
        case unhandledRegisteredCommand = "unhandled_registered_command"
        /// PRD-014: trace management requested while operation tracing is
        /// disabled — a no-op must never surface as success.
        case traceDisabled = "trace_disabled"
        /// Audio spectral analysis was accepted but the safe decoder/feature
        /// extraction path rejected the supplied artifact. The more specific
        /// engine code is carried in `analysis_error`.
        case spectralAnalysisFailed = "spectral_analysis_failed"
        case supportBundleExportFailed = "support_bundle_export_failed"
        /// PRD-015 (ADR-005 #288): `clear_traces` could not write its durable,
        /// append-only audit receipt (directory-create or append error), so the
        /// clear was REFUSED and the in-process trace store left intact —
        /// destroying evidence without a surviving receipt is the failure mode
        /// this debt closes. Terminal: no fallback channel or retry can create a
        /// filesystem path the operator's environment denies; the caller must
        /// fix the audit-log location.
        case traceClearReceiptFailed = "trace_clear_receipt_failed"
        case sagaInProgress = "saga_in_progress"
        case idempotencyKeyConflict = "idempotency_key_conflict"
        case sagaJournalCapacityExceeded = "saga_journal_capacity_exceeded"
        // LPMCP-PRD-005: the saga already reached a terminal state in this
        // session but its stored outcome body has been evicted under bounded
        // retention. Distinct from `sagaJournalCapacityExceeded`, which means
        // "cannot admit a NEW key".
        case sagaOutcomeUnavailable = "saga_outcome_unavailable"
        case notSupported = "not_supported"
        case sagaExecutionFailed = "saga_execution_failed"

        // #106 coordinate-free track M/S/R actuator — fail-closed honesty codes.
        /// The transport Record state was UNREADABLE at the arm post-actuate
        /// check, so the server cannot prove the arm key did not instead start
        /// transport recording. Distinct from `.axWriteFailed`: the write may have
        /// landed on the checkbox, but the honesty claim is unverifiable, so arm
        /// fails closed instead of returning State A (#2). NOT terminal — another
        /// channel (e.g. MCU) may arm through a different mechanism.
        case transportStateUnknown = "transport_state_unknown"
        /// A mute/arm key command was refused because the target track could not
        /// be proven EXCLUSIVELY selected (another track selected, or a header's
        /// selection state unreadable). Distinct from the generic write-fail hint
        /// so an operator is not misdirected to the key binding when selection is
        /// the problem (#5/#9). The key was never posted.
        case selectionNotExclusive = "selection_not_exclusive"
        case logicNotFrontmost = "logic_not_frontmost"
        /// A mute/arm synthetic key was refused because Logic's keyboard focus is
        /// not known-safe (an editable text field/sheet/combo box is focused), so
        /// posting the key would corrupt text or hit the wrong command (#6). The
        /// key was never posted.
        case unsafeFocusForSyntheticKey = "unsafe_focus_for_synthetic_key"
        /// The record-arm key override (`LOGIC_PRO_MCP_ARM_KEYCODE` /
        /// `LOGIC_PRO_MCP_ARM_KEY_MODIFIERS`) is present but invalid (unparseable
        /// keycode, unknown modifier token, or a bare no-modifier key). The arm
        /// path fails closed rather than silently posting the default or a partial
        /// chord (#7). The key was never posted.
        case armKeyConfigInvalid = "arm_key_config_invalid"
    }

    // MARK: - Encoding primitives

    /// State A — confirmed success (write + read-back matched). Extra fields
    /// (e.g. the original requested/observed payload) are merged in.
    static func encodeStateA(extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = ["success": true, "verified": true, "state": "A"]
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    /// State B — uncertain: the write landed but read-back couldn't confirm.
    /// `reason` is mandatory per the contract.
    static func encodeStateB(reason: UncertainReason, extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = [
            "success": true, "verified": false, "state": "B", "reason": reason.rawValue
        ]
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    /// State C — hard failure: the write itself didn't succeed. `error` is
    /// mandatory per the contract. `axCode` / `hint` are optional diagnostics.
    static func encodeStateC(
        error: FailureError,
        axCode: Int? = nil,
        hint: String? = nil,
        extras: [String: Any] = [:]
    ) -> String {
        var dict: [String: Any] = [
            "success": false, "state": "C", "error": error.rawValue
        ]
        if let axCode { dict["axCode"] = axCode }
        if let hint { dict["hint"] = hint }
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    // MARK: - HC v2 encoding (logic_plugins.* verified plugin surface only)

    /// HC v2 schema number. Carried as `hc_schema` so a client can branch on
    /// the richer verified-plugin envelope without sniffing for the presence
    /// of individual fields.
    static let schemaVersionV2 = 2

    /// HC v2 is an ADDITIVE superset used exclusively by `logic_plugins.*`:
    /// every envelope additionally carries `hc_schema`, and State C additionally
    /// carries `verified:false`. The v1 encoders above carry `state` but remain
    /// schema-free. Phase / success-vs-failure field requirements (what_was_*,
    /// safe_to_retry, target_identity, write_source, verify_source) are supplied
    /// by the caller through `extras` per the requirements §5.3 field table.
    static func encodeV2StateA(extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = [
            "success": true, "verified": true, "state": "A",
            "hc_schema": schemaVersionV2,
        ]
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    static func encodeV2StateB(reason: UncertainReason, extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = [
            "success": true, "verified": false, "state": "B",
            "hc_schema": schemaVersionV2, "reason": reason.rawValue,
        ]
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    /// Unlike v1 `encodeStateC`, the v2 failure envelope carries an explicit
    /// `verified:false` so a client that keys off `state`/`verified` sees a
    /// uniform tri-state contract. `success:false` + `error` are preserved so
    /// the detector and `ChannelRouter` terminal-state gate keep classifying
    /// it as State C unchanged.
    static func encodeV2StateC(error: FailureError, extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = [
            "success": false, "verified": false, "state": "C",
            "hc_schema": schemaVersionV2, "error": error.rawValue,
        ]
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    /// 이미 직렬화된 HC envelope (raw JSON) 의 top-level 에 caller-side extras
    /// 를 merge 한다. State C(`success == false`) 응답은 보존 — error payload
    /// 에 caller-side context 가 섞이면 진단성이 떨어지므로. 비-JSON / parse
    /// 실패 입력도 원본 그대로 반환 (defensive).
    static func addExtras(_ extras: [String: Any], into rawJSON: String) -> String {
        guard let data = rawJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return rawJSON
        }
        if (object["success"] as? Bool) == false {
            return rawJSON
        }
        for (k, v) in extras { object[k] = v }
        guard let encoded = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys]
              ),
              let str = String(data: encoded, encoding: .utf8) else {
            return rawJSON
        }
        return str
    }

    // MARK: - Terminal-state inspection (router fallback gate)

    /// Errors that mean "no other channel will do better either" — invalid
    /// caller input, missing element, explicit not-implemented. The router
    /// uses this to short-circuit the fallback chain so an AX honest State C
    /// does not silently regress into a vacuous MCU success on the next
    /// channel down (v3.1.2 P1-1).
    ///
    /// `ax_write_failed` and `permission_denied` are intentionally NOT
    /// terminal: a different channel (CGEvent, AppleScript, MCU) may still
    /// be able to deliver the operation.
    static let terminalErrorCodes: Set<String> = [
        FailureError.elementNotFound.rawValue,
        FailureError.invalidParams.rawValue,
        FailureError.notImplemented.rawValue,
        FailureError.portUnavailable.rawValue,
        FailureError.systemEventsAutomationDenied.rawValue,
        FailureError.readbackUnavailable.rawValue,
        FailureError.channelsExhausted.rawValue,
        // #140 — the file-open sheet never appeared; the menu route was driven
        // but no dialog surfaced, so no other channel can recover the missing
        // element. Terminal, mirroring `.elementNotFound`.
        FailureError.dialogNotFound.rawValue,
        // HC v2 verified-plugin path: every failure is terminal. The verified
        // surface routes through `[.accessibility]` alone (no fallback chain),
        // and falling back to Scripter/MCU would fabricate a false verified
        // result — so the router must never continue past any of these. These
        // codes are exclusive to `logic_plugins.*`; existing ops never emit
        // them, so this does not change any prior fallback behaviour.
        // `readbackMismatch` is deliberately NOT added here — it predates v2
        // and is shared with channels where fallback is still legitimate.
        FailureError.unsupportedMode.rawValue,
        FailureError.projectPathRequired.rawValue,
        FailureError.projectIdentityMismatch.rawValue,
        FailureError.unknownPluginIdentity.rawValue,
        FailureError.unsupportedParamReadback.rawValue,
        FailureError.incompleteInventory.rawValue,
        FailureError.targetPluginMismatch.rawValue,
        FailureError.pluginWindowPluginMismatch.rawValue,
        FailureError.duplicatePluginEditorAlreadyOpen.rawValue,
        FailureError.duplicatePluginEditorCountMismatch.rawValue,
        FailureError.slotOccupied.rawValue,
        FailureError.trackSelectionFailed.rawValue,
        FailureError.staleSnapshot.rawValue,
        FailureError.staleTargetReference.rawValue,
        FailureError.windowOpenFailed.rawValue,
        FailureError.windowIdentityUnresolved.rawValue,
        FailureError.paramControlNotFound.rawValue,
        FailureError.readbackLostAfterWrite.rawValue,
        FailureError.incrementWalkNoProgress.rawValue,
        FailureError.incrementWalkBudgetExhausted.rawValue,
        FailureError.incrementWalkOvershot.rawValue,
        FailureError.postInsertPluginMismatch.rawValue,
        FailureError.postInsertReadbackUnavailable.rawValue,
        FailureError.insertNotAxAutomatable.rawValue,
        FailureError.insertSetupFailed.rawValue,
        FailureError.insertLandedAtDifferentSlot.rawValue,
        FailureError.rollbackFailed.rawValue,
        FailureError.verifiedOpInProgress.rawValue,
        FailureError.mutatingOperationInProgress.rawValue,
        FailureError.operationTimeout.rawValue,
        // #144: `project.save` on an untitled document fails fast as terminal
        // State C `unsupported_state` — no fallback channel can save a document
        // that has no on-disk path; the caller must use `project.save_as`.
        FailureError.unsupportedState.rawValue,
        // #202: a deliberately not-exposed command token is terminal — no channel
        // can expose a surface the production contract intentionally omits.
        FailureError.commandNotExposed.rawValue,
        // #200: an out-of-range/empty indexed resource template read is terminal
        // — retrying the same index against the same project state can't succeed;
        // the client must read the parent collection for valid indices.
        FailureError.indexOutOfRange.rawValue,
        FailureError.folderNotPreset.rawValue,
        FailureError.internalInconsistency.rawValue,
        // #219: an unknown help category is terminal — no channel/retry can turn
        // a bad category token into a valid one; the caller must pick a listed
        // category. (help doesn't route through the fallback chain; listed for
        // classification consistency.)
        FailureError.unknownCategory.rawValue,
        FailureError.supportBundleExportFailed.rawValue,
        // PRD-015: a trace-clear receipt-write failure is terminal — no channel
        // or retry can create a path the operator's environment denies; the
        // store is left intact and the caller must fix the audit-log location.
        FailureError.traceClearReceiptFailed.rawValue,
        FailureError.idempotencyKeyConflict.rawValue,
        FailureError.sagaJournalCapacityExceeded.rawValue,
        // LPMCP-PRD-005: an evicted outcome body is terminal — no other channel
        // and no retry can reconstruct a body this session no longer holds. The
        // caller must reconcile with a live read.
        FailureError.sagaOutcomeUnavailable.rawValue,
    ]

    /// Returns true if the given message is a State-C envelope whose `error`
    /// is in `terminalErrorCodes`. Free-form (non-JSON) messages and State A
    /// / State B envelopes always return false. Used by `ChannelRouter` to
    /// suppress fallback when the primary channel has already reported an
    /// error the next channel cannot improve on.
    static func isTerminalStateC(_ message: String) -> Bool {
        guard let errorCode = stateCErrorCode(message) else { return false }
        return terminalErrorCodes.contains(errorCode)
    }

    /// Returns the stable State C error code for a valid Honest Contract
    /// failure envelope, or nil for free-form text / State A / State B.
    static func stateCErrorCode(_ message: String) -> String? {
        guard message.hasPrefix("{") else { return nil }
        guard let data = message.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            return nil
        }
        // State A / B both carry `success:true`; only State C is `false`.
        guard let success = obj["success"] as? Bool, success == false else {
            return nil
        }
        return obj["error"] as? String
    }

    /// Returns true when a valid State C envelope explicitly forbids the
    /// router from attempting the operation through another channel. This is
    /// distinct from `safe_to_retry`: callers may safely retry after changing
    /// state (for example, restoring keyboard focus) while a fallback channel
    /// would still be unsafe to invoke.
    static func isFallbackUnsafeStateC(_ message: String) -> Bool {
        guard message.hasPrefix("{") else { return false }
        guard let data = message.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            return false
        }
        // Encoders merge extras after their canonical fields, so `success:false` alone does not
        // prove State C. Require the complete State C shape before honoring this router directive.
        guard let success = obj["success"] as? Bool, success == false,
              let state = obj["state"] as? String, state == "C",
              obj["error"] as? String != nil else {
            return false
        }
        return obj["fallback_unsafe"] as? Bool == true
    }

    // MARK: - JSON serialization

    /// Serialize a dictionary deterministically (sorted keys) so snapshots
    /// and tests stay stable across runs. Values that JSONSerialization can't
    /// encode fall back to `String(describing:)`.
    static func jsonString(_ dict: [String: Any]) -> String {
        let sanitized = sanitize(dict)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                withJSONObject: sanitized, options: [.sortedKeys]
              ),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"success\":false,\"error\":\"honest_contract_encode_failed\"}"
        }
        return s
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = sanitize(v) }
            return out
        case let arr as [Any]:
            return arr.map { sanitize($0) }
        case let n as NSNumber:
            return n
        case let s as String:
            return s
        case let b as Bool:
            return b
        case let i as Int:
            return i
        case let d as Double:
            return d
        case is NSNull:
            return NSNull()
        case Optional<Any>.none:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}
