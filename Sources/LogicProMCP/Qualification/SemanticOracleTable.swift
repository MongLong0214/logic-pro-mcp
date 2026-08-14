import Foundation

// #373 Phase A — the oracle table.
//
// Every entry was derived by reading the operation's dispatcher handler and
// pinning what that handler ACTUALLY emits. Comments cite the handler so a
// future shape change is reconciled here rather than silently passing.
//
// Census invariant (meta-tested): the table's keys are exactly the registry's
// read-only specs whose availability is not `.unsupported`, minus
// `system.health` which keeps its bespoke full-payload equality validator.
//
// ── KNOWN GAPS (Phase A ships with these open; carried as Phase B debt) ──────
//
// 1. FIXTURE↔HANDLER DRIFT HAS NO AUTOMATIC GUARD. Every oracle here was
//    derived by READING its dispatcher, and the payloads in
//    SemanticOracleFixtures were hand-written to match. Nothing mechanically
//    binds the two: if a handler changes a key tomorrow, the fixture keeps the
//    old shape, the oracle keeps passing the stale fixture, and CI stays green
//    while the live surface has drifted. Phase B should close this by emitting
//    golden samples from the handlers' own encode paths, or by landing the
//    live-run drift catcher. Until then, treat green fixtures as evidence the
//    ORACLE LOGIC works — not as evidence the shapes are current.
//
// 2. SIX OPERATIONS CANNOT REACH `passed` UNDER THE CURRENT PROBE PARAMS. The
//    runner classifies on `isError` before any oracle runs, and these probes
//    are typed refusals by construction: project.export_plan,
//    plugins.get_inventory, tracks.resolve_path (empty params → invalid_params),
//    audio.analyze_file (empty params → unsafe_path), system.clear_traces
//    (probed `confirmed:false` on purpose, so qualification never destroys
//    diagnostic evidence), system.saga_status (probed with a key no record
//    exists for). Their oracles pin the real success contract and are unit- and
//    mutation-tested, but a live run cannot exercise them. Phase B: give these
//    probes qualifying params (a fixture project, a real track index, a seeded
//    saga) rather than weaken the oracles.
//
// 3. THREE MORE ARE ENVIRONMENT-CONDITIONAL live: project.get_regions,
//    tracks.list_library and tracks.scan_plugin_presets need Logic running with
//    (respectively) an arrange viewport, an open Library panel, and a focused
//    plugin window.
//
// 4. midi.list_ports' cross-check is a SAME-HANDLER ECHO, not an independent
//    readback — see its oracle's reason. No independent MIDI probe exists yet.

enum SemanticOracleTable {
    /// `system.health` is excluded: it has a bespoke validator that compares the
    /// entire typed `HealthResult` against the independent readback — a
    /// stronger check than any constraint list, and the only op whose readback
    /// resource returns the identical payload by construction.
    static let bespokeOperationIDs: Set<OperationID> = [.systemHealth]

    /// The read-only surface this table must FULLY cover, derived from the
    /// registry (the registry is truth — never a hand-maintained name list).
    /// Phase A/B0 invariant, unchanged: every read-only spec here has an oracle.
    static var coveredSpecIDs: Set<OperationID> {
        Set(
            OperationRegistry.specs
                .filter { $0.mutability == .readOnly && $0.availability != .unsupported }
                .map(\.id)
        )
        .subtracting(bespokeOperationIDs)
    }

    // ── #373 Phase B1 — DUAL census (generalize the census FIRST) ────────────
    //
    // Phase A/B0 covered ONLY the read-only surface, and the census pinned it
    // exactly: every read-only spec had an oracle, and every oracle mapped back
    // to a read-only spec. B1 begins the MUTATING surface, so a read-only-only
    // census can no longer be sound — a mutating oracle has no read-only spec to
    // map back to. The census is therefore generalized to two axes with DELIBER-
    // ATELY DIFFERENT completeness contracts:
    //
    //   * read-only  — FULLY covered (all 22; `coveredSpecIDs`), unchanged.
    //   * mutating   — covered INCREMENTALLY. B1 lands the verified-write oracles
    //                  below; B2/B3 add the rest. Full 51-op mutating coverage is
    //                  NOT required yet, so the census must not demand it.
    //
    // Soundness is kept by pinning the mutating increment EXACTLY
    // (`phaseB1MutatingOperationIDs`) and by proving every id in it is a real
    // `.mutating`, non-`.unsupported` registry spec — a read-only id or a typo
    // cannot masquerade as mutating coverage, and the read-only 22 stay pinned.

    /// The mutating operations B1 covers with a verified-write (State A) oracle.
    /// Each was derived by READING its dispatcher/channel handler and pinning
    /// what its `encodeStateA` / `encodeV2StateA` envelope actually emits (cited
    /// per oracle below). NOT the whole mutating surface — an explicit increment.
    ///
    /// mixer.set_plugin_param is DELIBERATELY ABSENT: it routes to `[.scripter]`,
    /// whose handler emits only State B (`readback_unavailable`,
    /// `scripter_send_only`) — a send-only write that never reaches State A, so it
    /// has no verified envelope to pin and cannot be an honest B1 oracle. It stays
    /// uncovered until a State-B honest-contract oracle class exists.
    static let phaseB1MutatingOperationIDs: Set<OperationID> = [
        .mixerSetVolume, .mixerSetPan, .mixerSetMasterVolume,
        .tracksSelect, .tracksRename, .tracksMute, .tracksSolo, .tracksArm,
        .tracksArmOnly, .tracksSetAutomation, .tracksSetInstrument,
        .pluginsSetParamVerified,
    ]

    /// The mutating operations B2 covers with a verified-write (State A) oracle:
    /// the transport + navigate safe-mutation surface. Each was derived by READING
    /// its dispatcher/channel handler and pinning what its `encodeStateA` envelope
    /// actually emits (cited per oracle below). Like B1 this is an EXPLICIT
    /// increment, not the whole mutating surface — B3 adds the rest.
    ///
    /// COVERAGE CREDIT (#409): defining an oracle here is INVENTORY, not coverage.
    /// R-SEM (`semanticCoverageIncomplete`) is credited to an operation ONLY when it
    /// is live-exercised to a `.passed` semanticReadback verdict (the #284 live
    /// matrix) or covered by a governed release-visible waiver — never by an oracle's
    /// mere existence. So this B2 increment PINS the State-A contract these
    /// transport/navigate writes must satisfy in the future live run; it does NOT
    /// itself reduce the R-SEM static debt.
    ///
    /// DELIBERATELY ABSENT (audited, no State-A envelope to verify — see
    /// `structurallyUnverifiedMutatingOperationIDs`): transport.rewind,
    /// transport.fast_forward, navigate.zoom_to_fit, navigate.toggle_view.
    /// Every one routes ONLY to send-only channels
    /// (MCU / MIDIKeyCommands / CGEvent) whose handlers emit State B
    /// `readback_unavailable` with no read-back — there is no State A to pin, so a
    /// verified-write oracle would have to invent a contract the handler can never
    /// produce. transport.set_cycle_range is excluded a level earlier: it is
    /// registry `.unsupported`, so `mutatingSpecIDs` already filters it out (see
    /// `unsupportedExcludedMutatingOperationIDs`).
    static let phaseB2MutatingOperationIDs: Set<OperationID> = [
        // transport (10 of the 12 audited — rewind/fast_forward are send-only)
        .transportPlay, .transportStop, .transportRecord, .transportPause,
        .transportToggleCycle, .transportToggleMetronome, .transportToggleCountIn,
        .transportToggleAutopunch, .transportSetTempo, .transportGotoPosition,
        // navigate (6 of the 8 audited — zoom_to_fit/toggle_view are send-only)
        .navigateGotoBar, .navigateGotoMarker, .navigateCreateMarker,
        .navigateDeleteMarker, .navigateRenameMarker, .navigateSetZoom,
    ]

    /// The mutating operations B3 covers with a verified-write (State A) oracle:
    /// the project-lifecycle / tracks-topology / system-saga / midi-import
    /// surface — the remaining verified-write mutating ops in the project, tracks,
    /// system, and midi tools that reach a genuine State A. Each was DERIVED BY
    /// READING its dispatcher/channel handler and pinning what the verified path
    /// actually emits (cited per oracle below). Like B1/B2 this is an EXPLICIT
    /// increment, not the whole mutating surface — the edit surface, the
    /// mixer/plugin inserts, and the export/cleanup executors remain future work.
    ///
    /// COVERAGE CREDIT (#409): defining an oracle here is INVENTORY, not coverage.
    /// R-SEM (`semanticCoverageIncomplete`) is credited to an operation ONLY when it
    /// is live-exercised to a `.passed` semanticReadback verdict (the #284 live
    /// matrix) or covered by a governed release-visible waiver — never by an oracle's
    /// mere existence. So this B3 increment PINS the State-A contract these
    /// verified writes must satisfy in the future live run; it does NOT itself
    /// reduce the R-SEM static debt, and it does not change
    /// `ProductionReadinessContracts` coverage-credit logic.
    ///
    /// DELIBERATELY ABSENT (audited, no verifiable State A — see
    /// `structurallyUnverifiedMutatingOperationIDs`): project.new / project.open
    /// (AppleScript lifecycle → honest State B readback_unavailable, never A),
    /// project.close (VerificationPolicy.none, same State-B ceiling), project.launch
    /// / project.quit (a prose success string gated on a running-state poll, not an
    /// HC envelope), tracks.duplicate (VerificationPolicy.none, send-only), and the
    /// send-only midi surface (send_*/mmc_play/mmc_stop/mmc_record/play_sequence/
    /// step_input/create_virtual_port — every one routes to a send-only channel that
    /// emits State B send_only_no_readback with no read-back).
    static let phaseB3MutatingOperationIDs: Set<OperationID> = [
        // project (3 of the 8 lifecycle ops audited — new/open/close/launch/quit
        // reach no State A; save_as is envelope-only, see its oracle)
        .projectSave, .projectSaveAs, .projectBounce,
        // tracks (6 — the 4 create_* + delete + record_sequence topology writes)
        .tracksCreateAudio, .tracksCreateInstrument, .tracksCreateDrummer,
        .tracksCreateExternalMIDI, .tracksDelete, .tracksRecordSequence,
        // system (4 — the saga executors + the consent-gated arm-key setup + the
        // support-bundle write)
        .systemSagaExecute, .systemSagaCancel, .systemSetupArmKey,
        .systemExportSupportBundle,
        // midi (2 — the AX-menu import + the bar-path MMC locate; the rest of the
        // midi surface is send-only, see the exclusions)
        .midiImportFile, .midiMMCLocate,
    ]

    /// The mutating operations B4 covers with a verified-execution oracle: the
    /// FINAL uncovered mutating surface — the two plugin-insert paths, the export
    /// executors, the cleanup-apply executor, and the one edit op that reaches a
    /// genuine State A. Each was DERIVED BY READING its dispatcher/channel handler
    /// and pinning what the verified path actually emits (cited per oracle below).
    /// With this increment EVERY supported (non-`.unsupported`) mutating op is
    /// either covered here or carries an audited structural exclusion — the
    /// pure-code mutating oracle inventory is CLOSED (asserted by
    /// `everyMutatingSpecIsCoveredOrAuditedExcluded`).
    ///
    /// COVERAGE CREDIT (#409): defining an oracle here is INVENTORY, not coverage.
    /// R-SEM (`semanticCoverageIncomplete`) is credited to an operation ONLY when it
    /// is live-exercised to a `.passed` semanticReadback verdict (the #284 live
    /// matrix) or covered by a governed release-visible waiver — never by an oracle's
    /// mere existence. So this B4 increment PINS the State-A contract these verified
    /// executions must satisfy in the future live run; it does NOT itself reduce the
    /// R-SEM static debt, and it does not change `ProductionReadinessContracts`.
    ///
    /// DELIBERATELY ABSENT (audited, no State-A envelope — see
    /// `structurallyUnverifiedMutatingOperationIDs`): the 13 send-only edit ops
    /// (undo/redo/cut/copy/paste/delete/select_all/split/join/quantize/
    /// bounce_in_place/normalize/duplicate). Every one routes ONLY to
    /// [.midiKeyCommands, .cgEvent] (RoutingTable) — a blind CC key command or a
    /// CGEvent keystroke — and BOTH channels emit State B (send_only_no_readback /
    /// readback_unavailable) with no edit read-back, so no State A exists.
    /// edit.toggle_step_input is the one edit op that DOES reach State A (its
    /// [.accessibility, …] chain verifies the Step Input Keyboard window open-state
    /// flipped via an AX window-list read-back), so it is covered, not excluded.
    static let phaseB4MutatingOperationIDs: Set<OperationID> = [
        // mixer (1 — the AX slot-popup insert that reads back the slot name)
        .mixerInsertPlugin,
        // plugins (1 — the verified apply-back insert, HC v2 State A)
        .pluginsInsertVerified,
        // project (3 — the two export executors + the cleanup-apply rename executor)
        .projectExportRun, .projectExportResume, .projectCleanupApply,
        // edit (1 — the sole edit op with an AX State-A path; the other 13 are send-only)
        .editToggleStepInput,
    ]

    /// Every mutating operation the table covers: the B1 verified-write increment
    /// UNION the B2 transport/navigate increment UNION the B3
    /// project/tracks/system/midi increment UNION the B4 plugin-insert / export /
    /// cleanup / edit increment. B4 is the FINAL increment: with it, the covered set
    /// plus `structurallyUnverifiedMutatingOperationIDs` account for the ENTIRE
    /// mutating surface (`everyMutatingSpecIsCoveredOrAuditedExcluded`), so the
    /// pure-code mutating oracle inventory is closed — no mutating spec is left
    /// implicitly uncovered.
    static var coveredMutatingOperationIDs: Set<OperationID> {
        phaseB1MutatingOperationIDs
            .union(phaseB2MutatingOperationIDs)
            .union(phaseB3MutatingOperationIDs)
            .union(phaseB4MutatingOperationIDs)
    }

    /// The mutating surface (non-`.unsupported`), from the registry. Coverage is
    /// INCREMENTAL — unlike `coveredSpecIDs`, the table need not cover all of this
    /// yet; `phaseB1MutatingOperationIDs` is the covered subset.
    static var mutatingSpecIDs: Set<OperationID> {
        Set(
            OperationRegistry.specs
                .filter { $0.mutability == .mutating && $0.availability != .unsupported }
                .map(\.id)
        )
    }

    /// Every operation the table may legitimately carry an oracle for: the FULLY
    /// covered read-only surface UNION the mutating surface. An oracle outside
    /// this union is dead weight (no spec) or bound to an unsupported spec — the
    /// census forbids both.
    static var supportedOracleSurface: Set<OperationID> {
        coveredSpecIDs.union(mutatingSpecIDs)
    }

    /// Mutating ops AUDITED in B1 and found to have NO verifiable State-A envelope
    /// — deliberately, STRUCTURALLY excluded from the verified-write oracle set
    /// (not merely "not yet phased in"), each with the reason. Kept EXPLICIT so
    /// the exclusion is a reviewed decision, not an accidental gap: the census
    /// asserts each is a real mutating spec, is DISJOINT from the covered set, and
    /// carries a reason — so the uncovered complement is never fully implicit.
    static let structurallyUnverifiedMutatingOperationIDs: [OperationID: String] = [
        .mixerSetPluginParam:
            "send-only State B — routes to [.scripter], whose handler emits only "
            + "readback_unavailable / scripter_send_only; there is no State A to verify",
        // B2 audit: these four transport/navigate ops route ONLY to send-only
        // channels and their handlers can never reach State A. Kept explicit so
        // their absence from the B2 increment is a reviewed decision, not a gap.
        .transportRewind:
            "send-only — routes to [.mcu, .coreMIDI, .cgEvent]; MCUChannel.sendTransport "
            + "and the keystroke channels emit only State B readback_unavailable, so a "
            + "rewind press has no read-back and no State A to verify",
        .transportFastForward:
            "send-only — routes to [.mcu, .coreMIDI, .cgEvent] exactly like rewind; the "
            + "MCU/CoreMIDI/CGEvent transport presses are echo-less, so no State A exists",
        .navigateZoomToFit:
            "send-only — routes to [.midiKeyCommands, .cgEvent]; both fire a blind key "
            + "command (CC 46 / key Z) with no arrange-zoom read-back, so the op is honestly "
            + "State B and never reaches a verified State A",
        .navigateToggleView:
            "send-only — routes each view to [.midiKeyCommands, .cgEvent] (view.toggle_*); "
            + "the key command fires blind with no view-state read-back, so no State A exists",
        // B3 audit: project-lifecycle / tracks-topology / midi-send ops that
        // structurally cannot reach State A. Kept explicit so their absence from
        // the B3 increment is a reviewed decision, not a gap.
        .projectNew:
            "AppleScript lifecycle write — chain [.appleScript, .cgEvent]; the successful "
            + "new-document path wraps through AppleScriptChannel.wrapMutatingResult, which "
            + "always emits honest State B readback_unavailable. The front-document-identity "
            + "change only gates State C-vs-B (didFrontDocumentChange), never State A, so no "
            + "verified-write envelope is emitted",
        .projectOpen:
            "AppleScript lifecycle write — chain [.appleScript]; openProjectViaWorkspace returns "
            + "a plain 'Opened: <path>' success that wrapMutatingResult wraps as State B "
            + "readback_unavailable. No State A envelope exists",
        .projectClose:
            "VerificationPolicy.none — chain [.appleScript, .cgEvent]; the close script success "
            + "is wrapped by wrapMutatingResult as State B readback_unavailable, so there is no "
            + "State A to verify",
        .projectLaunch:
            "ProjectDispatcher.runLifecycleScript returns a prose success string "
            + "('Logic Pro launched') gated on a running-state poll, NOT an HonestContract "
            + "State-A envelope — there is no state/verified/success envelope to compose a "
            + "verified-write oracle from",
        .projectQuit:
            "ProjectDispatcher.runLifecycleScript returns a prose success string "
            + "('Logic Pro quit') gated on a running-state poll, NOT an HonestContract State-A "
            + "envelope; the running-state check is the verification but the response body is "
            + "prose, not a verified-write envelope",
        .tracksDuplicate:
            "VerificationPolicy.none — routes [.midiKeyCommands, .cgEvent] (no accessibility "
            + "channel handles track.duplicate), and both emit send-only State B "
            + "send_only_no_readback; there is no topology read-back and no State A",
        .midiSendNote:
            "send-only VerificationPolicy.none — routes [.coreMIDI], whose handler emits State B "
            + "send_only_no_readback; a raw MIDI note send has no read-back and no State A",
        .midiSendChord:
            "send-only VerificationPolicy.none — routes [.coreMIDI] → State B "
            + "send_only_no_readback; a chord send is echo-less, so no State A exists",
        .midiSendCC:
            "send-only VerificationPolicy.none — routes [.coreMIDI] → State B "
            + "send_only_no_readback; a control-change send has no read-back and no State A",
        .midiSendProgramChange:
            "send-only VerificationPolicy.none — routes [.coreMIDI] → State B "
            + "send_only_no_readback; a program-change send is echo-less, so no State A",
        .midiSendPitchBend:
            "send-only VerificationPolicy.none — routes [.coreMIDI] → State B "
            + "send_only_no_readback; a pitch-bend send has no read-back and no State A",
        .midiSendAftertouch:
            "send-only VerificationPolicy.none — routes [.coreMIDI] → State B "
            + "send_only_no_readback; an aftertouch send is echo-less, so no State A",
        .midiSendSysEx:
            "send-only VerificationPolicy.none — routes [.coreMIDI] → State B "
            + "send_only_no_readback; a SysEx send has no read-back and no State A",
        .midiPlaySequence:
            "send-only VerificationPolicy.none — routes [.coreMIDI], which streams the note "
            + "sequence and returns State B send_only_no_readback; there is no arrangement "
            + "read-back and no State A",
        .midiStepInput:
            "send-only VerificationPolicy.none — routes [.coreMIDI] step-input send → State B "
            + "send_only_no_readback; the stepped note has no read-back and no State A",
        .midiCreateVirtualPort:
            "VerificationPolicy.none — CoreMIDIChannel.createSendOnlyPort creates a send-only "
            + "virtual port and returns State B send_only_no_readback; port creation exposes no "
            + "verified read-back and no State A",
        .midiMMCPlay:
            "send-only VerificationPolicy.none — routes mmc.play to [.coreMIDI]; the MMC "
            + "transport SysEx is echo-less (State B send_only_no_readback), so no State A exists",
        .midiMMCStop:
            "send-only VerificationPolicy.none — routes mmc.stop to [.coreMIDI]; the MMC "
            + "transport SysEx is echo-less (State B send_only_no_readback), so no State A exists",
        .midiMMCRecord:
            "send-only VerificationPolicy.none — routes mmc.record_strobe to [.coreMIDI]; the MMC "
            + "record SysEx is echo-less (State B send_only_no_readback), so no State A exists",
        // B4 audit: the 13 send-only edit ops. Every one routes ONLY to
        // [.midiKeyCommands, .cgEvent] (RoutingTable) — a blind CC key command
        // (MIDIKeyCommandsChannel) or a CGEvent keystroke (CGEventChannel) — and
        // BOTH channels emit State B (send_only_no_readback / readback_unavailable)
        // with no edit read-back, so no State A exists. Kept explicit so their
        // absence from the B4 increment is a reviewed decision, not a gap.
        // (edit.toggle_step_input is NOT here: its [.accessibility, …] chain reaches
        // a genuine State A — it is B4-covered, not excluded.)
        .editUndo:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+Z "
            + "keystroke); both channels emit State B send_only_no_readback with no undo "
            + "read-back, so there is no State A to verify",
        .editRedo:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+Shift+Z "
            + "keystroke); the keystroke is echo-less (State B send_only_no_readback), so no State A",
        .editCut:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+X "
            + "keystroke); the clipboard cut has no arrange read-back and emits State B "
            + "send_only_no_readback, so no State A exists",
        .editCopy:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+C "
            + "keystroke); a copy is echo-less (State B send_only_no_readback), so no State A",
        .editPaste:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+V "
            + "keystroke); the paste has no arrange read-back and emits State B "
            + "send_only_no_readback, so no State A exists",
        .editDelete:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Delete "
            + "keystroke); the delete has no arrange read-back and emits State B "
            + "send_only_no_readback, so no State A exists",
        .editSelectAll:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+A "
            + "keystroke); the dispatcher maps its unverified State B to isError, and neither "
            + "channel reads the selection back, so no State A exists",
        .editSplit:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+T "
            + "keystroke); the split is echo-less (State B send_only_no_readback), so no State A",
        .editJoin:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Cmd+J "
            + "keystroke); the join is echo-less (State B send_only_no_readback), so no State A",
        .editQuantize:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / Q "
            + "keystroke); the dispatcher maps its unverified State B to isError, and neither "
            + "channel reads the quantized grid back, so no State A exists",
        .editBounceInPlace:
            "send-only — routes [.midiKeyCommands, .cgEvent] (blind CC key command / CGEvent "
            + "keystroke); bounce-in-place has no region read-back and emits State B "
            + "send_only_no_readback, so no State A exists",
        .editNormalize:
            "send-only VerificationPolicy.none — routes [.midiKeyCommands, .cgEvent] (blind CC "
            + "key command / keystroke; availability .requiresKeyBinding is a SETUP axis, not the "
            + "reason it lacks State A); the normalize is echo-less (State B), so no State A exists",
        .editDuplicate:
            "send-only VerificationPolicy.none — routes [.midiKeyCommands, .cgEvent] (blind CC "
            + "key command / keystroke; availability .requiresKeyBinding is a SETUP axis, not the "
            + "reason it lacks State A); the duplicate is echo-less (State B), so no State A exists",
    ]

    /// Mutating ops that never enter the oracle surface at all because the
    /// registry marks them `.unsupported` — `mutatingSpecIDs` filters
    /// `availability != .unsupported`, so they are excluded a level BEFORE the
    /// structural-exclusion list above (which is for SUPPORTED mutating specs that
    /// still lack a State-A envelope). Kept explicit + reasoned so the
    /// `.unsupported` exclusion is documented, not merely implied by the filter.
    static let unsupportedExcludedMutatingOperationIDs: [OperationID: String] = [
        .transportSetCycleRange:
            "registry .unsupported — Logic 12.x exposes no numeric cycle-locator AX fields, "
            + "so AccessibilityChannel.defaultSetCycleRange fails closed with State C "
            + "not_implemented and can never verify a write; excluded from mutatingSpecIDs",
    ]

    static let all: [OperationOracle] = [
        systemPermissions,
        systemRefreshCache,
        systemHelp,
        systemListRecentTraces,
        systemGetTrace,
        systemClearTraces,
        systemSagaPreflight,
        systemSagaStatus,
        pluginsGetInventory,
        projectIsRunning,
        projectGetRegions,
        projectExportPlan,
        projectAudit,
        projectCleanupPlan,
        audioAnalyzeFile,
        audioAnalyzeSpectrum,
        audioRecommendEQ,
        midiListPorts,
        tracksListLibrary,
        tracksScanLibrary,
        tracksResolvePath,
        tracksScanPluginPresets,
        // #373 Phase B1 — verified-write safe-mutation oracles (State A).
        mixerSetVolume,
        mixerSetPan,
        mixerSetMasterVolume,
        tracksSelect,
        tracksRename,
        tracksMute,
        tracksSolo,
        tracksArm,
        tracksArmOnly,
        tracksSetAutomation,
        tracksSetInstrument,
        pluginsSetParamVerified,
        // #373 Phase B2 — transport + navigate safe-mutation oracles (State A).
        transportPlay,
        transportStop,
        transportRecord,
        transportPause,
        transportToggleCycle,
        transportToggleMetronome,
        transportToggleCountIn,
        transportToggleAutopunch,
        transportSetTempo,
        transportGotoPosition,
        navigateGotoBar,
        navigateGotoMarker,
        navigateCreateMarker,
        navigateDeleteMarker,
        navigateRenameMarker,
        navigateSetZoom,
        // #373 Phase B3 — project/tracks/system/midi verified-write oracles.
        projectSave,
        projectSaveAs,
        projectBounce,
        tracksCreateAudio,
        tracksCreateInstrument,
        tracksCreateDrummer,
        tracksCreateExternalMIDI,
        tracksDelete,
        tracksRecordSequence,
        systemSagaExecute,
        systemSagaCancel,
        systemSetupArmKey,
        systemExportSupportBundle,
        midiImportFile,
        midiMMCLocate,
        // #373 Phase B4 — plugin-insert / export / cleanup / edit verified-execution oracles.
        mixerInsertPlugin,
        pluginsInsertVerified,
        projectExportRun,
        projectExportResume,
        projectCleanupApply,
        editToggleStepInput,
    ]

    static let byOperationID: [OperationID: OperationOracle] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.operationID, $0) }
    )

    /// Escape-hatch tax.
    ///
    /// DEVIATION from the ratified design, reported rather than improvised: the
    /// ratified budget was "≤5 of the set may be .custom". Against the real
    /// handler shapes that budget is infeasible — SEVEN read-only operations
    /// cannot carry any declarative VALUE constraint:
    ///
    ///   * prose bodies, no key to bind to:
    ///       system.permissions, system.refresh_cache, system.help
    ///   * bare-scalar body, no key to bind to:
    ///       project.is_running
    ///   * JSON with zero constant-valued fields:
    ///       midi.list_ports, tracks.list_library, tracks.resolve_path
    ///
    /// The root cause is a gap in the constraint data model, not laziness: a
    /// constraint binds to ONE payload and has no cross-check case, and there is
    /// no implication case. For these seven the only honest checks ARE
    /// cross-checks and conditionals. Forcing them under a numeric cap would
    /// have produced tautological oracles (`enumMember` over a field a
    /// `typedField` already types) — checkbox oracles of exactly the kind this
    /// ticket exists to forbid.
    ///
    /// So the cap is replaced by something stricter than "≤5": an explicit
    /// allowlist. A new `.custom` oracle cannot appear without editing this set,
    /// which is the review gate the budget was reaching for.
    ///
    /// Phase B recommendation: add `.crossCheck` and `.implies` constraint cases;
    /// midi.list_ports, tracks.list_library, tracks.resolve_path and
    /// project.is_running all become declarative, taking the hatch back to the
    /// three irreducible prose bodies.
    static let sanctionedCustomOperationIDs: Set<OperationID> = [
        .systemPermissions,
        .systemRefreshCache,
        .systemHelp,
        .projectIsRunning,
        .midiListPorts,
        .tracksListLibrary,
        .tracksResolvePath,
    ]

    static var customOracles: [OperationOracle] { all.filter { $0.strength == .custom } }

    // MARK: - system

    // SystemDispatcher `case "permissions"` → toolTextResult(status.summary).
    // PermissionChecker.summary is human-readable prose, one line per
    // permission, each ending in a state label.
    static let systemPermissions = OperationOracle(
        custom: .systemPermissions,
        reason: """
            The handler returns PermissionChecker.summary — human-readable prose, \
            not JSON. There is no key-addressable field for a declarative \
            constraint to bind to, so the four required permission lines and \
            their legal state labels are asserted in the closure.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        let requiredPrefixes = [
            "Accessibility: ",
            "Automation (Logic Pro): ",
            "Automation (System Events): ",
            "PostEvent (CGEvent): ",
        ]
        // The closed set of line remainders PermissionChecker.summary can emit:
        // State.summaryLabel's three values, plus the one hardcoded variant the
        // Automation (Logic Pro) notVerifiable branch appends. Matched EXACTLY —
        // a prefix match would accept "granted_evil" or "NOT GRANTEDish" and
        // wave through a label this code has never seen.
        let legalLabels: Set<String> = [
            "granted",
            "NOT GRANTED",
            "NOT VERIFIABLE",
            "NOT VERIFIABLE (Logic Pro not running)",
        ]
        let lines = text.split(separator: "\n").map(String.init)
        return requiredPrefixes.allSatisfy { prefix in
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return false }
            return legalLabels.contains(String(line.dropFirst(prefix.count)))
        }
    }

    // SystemDispatcher `case "refresh_cache"` → one of exactly two sentences,
    // depending on whether an AX fallback poller is attached.
    static let systemRefreshCache = OperationOracle(
        custom: .systemRefreshCache,
        reason: """
            The handler returns a bare prose sentence, not JSON. The legal \
            bodies are a closed two-element set, but with no JSON key to bind \
            an enumMember constraint to, the set is enumerated in the closure.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        let legalBodies = [
            "State refresh completed via AX fallback poller.",
            "State refresh triggered. Cache will be updated on next poll cycle.",
        ]
        return legalBodies.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // SystemDispatcher `case "help"` → Self.helpText(for: category). The
    // qualification probe passes category "system" (QualificationTransport
    // .probeParams), so the body must be the logic_system section — not the
    // full help, and not another dispatcher's section.
    static let systemHelp = OperationOracle(
        custom: .systemHelp,
        reason: """
            The handler returns a formatted help document, not JSON. The check \
            that matters — that the probe's `category:"system"` was honoured and \
            the section documents the real logic_system surface — is a prose \
            assertion no key-addressable constraint can express.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        // Honouring `category:"system"` means the SYSTEM section, not full help.
        guard text.hasPrefix("logic_system commands:") else { return false }
        // The section must document the system commands the registry exposes.
        let requiredCommands = [
            "health", "permissions", "refresh_cache", "list_recent_traces",
            "get_trace", "clear_traces", "saga_preflight", "saga_execute",
            "saga_status", "saga_cancel", "help",
        ]
        guard requiredCommands.allSatisfy({ text.contains("\n  \($0)") || text.contains("  \($0) ") })
        else {
            return false
        }
        // The category enumeration must list every accepted help category.
        return text.contains("Categories: transport, tracks, mixer, midi, edit, "
            + "navigate, project, audio, plugins, system")
    }

    // SystemDispatcher `case "list_recent_traces"` →
    // {"traces":[{trace_id, operation_id, phase_count, readback_state?}]}.
    // The qualification drive seeds exactly one saga_execute trace before this
    // probe runs, so the list cannot be empty and its entries cannot be hollow:
    // a trace claiming zero phases is a lie about what was recorded.
    static let systemListRecentTraces = OperationOracle(
        .systemListRecentTraces,
        strength: .shapeAndDomain,
        constraints: [
            .typedField(key: "traces", type: .array),
            .nonEmptyArray(key: "traces"),
            .typedField(key: "traces.0.trace_id", type: .string),
            .typedField(key: "traces.0.operation_id", type: .string),
            .numericRange(key: "traces.0.phase_count", min: 1, max: 100_000),
        ]
    )

    // SystemDispatcher `case "get_trace"` →
    // {"trace_id", "operation_id", "events":[{phase, timestamp, attributes}]}.
    // The probe always reads back the trace the drive seeded, and the drive
    // seeds it via system.saga_execute (QualificationTransport asserts
    // `$0.operationID == OperationID.systemSagaExecute.rawValue`), so the
    // operation_id is exactly pinnable — this oracle catches a handler that
    // returns SOME trace rather than the requested one.
    static let systemGetTrace = OperationOracle(
        .systemGetTrace,
        strength: .shapeAndDomain,
        constraints: [
            .typedField(key: "trace_id", type: .string),
            .valueEquals(key: "operation_id", expected: .string(OperationID.systemSagaExecute.rawValue)),
            .nonEmptyArray(key: "events"),
            .enumMember(key: "events.0.phase", allowed: TracePhase.allCases.map(\.rawValue)),
        ]
    )

    // SystemDispatcher `case "clear_traces"` success →
    // {"success":true, "receipt_path":String, "cleared_trace_count":Int}.
    // NOTE: unreachable under the current probe, which sends `confirmed:false`
    // on purpose so qualification never destroys diagnostic evidence. That
    // yields a typed State C and the runner classifies on isError before the
    // oracle is consulted. The oracle still pins the success contract so a
    // future confirmed probe (or a handler regression) is checked.
    static let systemClearTraces = OperationOracle(
        .systemClearTraces,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "success", expected: .bool(true)),
            .typedField(key: "receipt_path", type: .string),
            .numericRange(key: "cleared_trace_count", min: 0, max: 100_000),
        ]
    )

    // SystemDispatcher `case "saga_preflight"` → SagaWire.sessionFields +
    // {"ok", "issues", "before_state_availability", "writes_performed": 0}.
    // writes_performed == 0 is the load-bearing honesty claim: a preflight that
    // wrote anything is a contract violation regardless of what it reports.
    static let systemSagaPreflight = OperationOracle(
        .systemSagaPreflight,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "writes_performed", expected: .number(0)),
            .valueEquals(key: "journal_scope", expected: .string("session")),
            .valueEquals(
                key: "journal_persistence",
                expected: .string("cleared_on_server_session_end")
            ),
            .valueEquals(key: "journal_survives_process_restart", expected: .bool(false)),
            .typedField(key: "ok", type: .bool),
            .typedField(key: "issues", type: .array),
        ]
    )

    // SystemDispatcher `case "saga_status"` success → sessionFields +
    // {"idempotency_key", "record": {"status", ...}}.
    // NOTE: unreachable under the current probe, which asks for the key
    // "qualification-read-probe" that no probe ever creates a record for; the
    // handler answers elementNotFound (State C, isError) and the runner
    // classifies before the oracle runs. The oracle pins the success contract.
    static let systemSagaStatus = OperationOracle(
        .systemSagaStatus,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "journal_scope", expected: .string("session")),
            .valueEquals(key: "journal_survives_process_restart", expected: .bool(false)),
            .typedField(key: "idempotency_key", type: .string),
            .enumMember(
                key: "record.status",
                allowed: ["in_progress", "cancellation_requested", "cancelled", "completed"]
            ),
        ]
    )

    // MARK: - plugins

    // AccessibilityChannel+VerifiedPlugins `defaultGetPluginInventory` success →
    // HC v2 envelope + {track, plugins_source, plugins, complete, ...}.
    // NOTE: unreachable under the current probe, which sends empty params; the
    // handler requires `track` and answers a typed HC v2 invalid_params State C.
    static let pluginsGetInventory = OperationOracle(
        .pluginsGetInventory,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "hc_schema", expected: .number(2)),
            // State A ONLY. State B is an honest `readback_unavailable` — the
            // handler is telling us it could not see the insert chain, and its
            // extras omit `plugins` entirely. Two reasons this must not qualify:
            //   1. Semantics: a qualification `passed` means the operation was
            //      SEMANTICALLY VERIFIED. State B is by construction unverified;
            //      passing it would launder "I couldn't check" into "checked".
            //   2. Consistency: allowing {A,B} while requiring a typed `plugins`
            //      array would false-FAIL every honest State B, since B omits it.
            // Resolved strict rather than loose: pin A, keep the plugins array.
            .valueEquals(key: "state", expected: .string("A")),
            .numericRange(key: "track", min: 0, max: 10_000),
            .typedField(key: "plugins", type: .array),
        ]
    )

    // MARK: - project

    // ProjectDispatcher `case "is_running"` →
    // toolTextResult(isLogicProRunning() ? "true" : "false").
    static let projectIsRunning = OperationOracle(
        custom: .projectIsRunning,
        reason: """
            The whole body is a bare scalar literal — `true` or `false` — with \
            no key to address. A constraint on the root key path could only \
            restate "is a boolean", which the JSON type already implies; that \
            is a presence check wearing a value constraint's clothes. The real \
            contract is byte-exact: exactly one of two literals, so prose, an \
            envelope, a quoted "true", or `True` are all caught.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        return ["true", "false"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // AccessibilityChannel+Regions `defaultGetRegions` → RegionInventoryPayload.
    // complete/scope/reason are hardcoded honesty disclaimers: this read only
    // ever sees the visible arrange viewport, and it must never claim otherwise.
    static let projectGetRegions = OperationOracle(
        .projectGetRegions,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "complete", expected: .bool(false)),
            .valueEquals(key: "scope", expected: .string("visible_arrange_area")),
            .valueEquals(key: "reason", expected: .string("logic_ax_viewport_only")),
            .numericRange(key: "returned_count", min: 0, max: 100_000),
            .typedField(key: "regions", type: .array),
        ]
    )

    // ProjectExportPlannerModels `ProjectExportPlan` CodingKeys.
    // NOTE: unreachable under the current probe (empty params; the planner
    // requires `projects`/`project`/`path` and answers invalid_params).
    // execution_mode/next_safe_action are the plan's dry-run guarantees.
    static let projectExportPlan = OperationOracle(
        .projectExportPlan,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_export_manifest.v1")),
            .valueEquals(key: "execution_mode", expected: .string("dry_run_only")),
            .valueEquals(key: "next_safe_action", expected: .string("review_export_plan")),
            .enumMember(key: "status", allowed: ["planned", "degraded"]),
            .numericRange(key: "project_count", min: 0, max: 100_000),
            .typedField(key: "projects", type: .array),
        ]
    )

    // ProjectSessionAudit `AuditReport`. read_only:true is hardcoded and
    // load-bearing: the audit promises it touched nothing.
    static let projectAudit = OperationOracle(
        .projectAudit,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_project_audit.v1")),
            .valueEquals(key: "read_only", expected: .bool(true)),
            .enumMember(key: "status", allowed: ["ok", "degraded", "failed"]),
            .numericRange(key: "project.track_count", min: 0, max: 10_000),
            .typedField(key: "findings", type: .array),
            .typedField(key: "evidence", type: .object),
        ]
    )

    // ProjectSessionAudit `CleanupPlanReport`. source_audit_schema binds the
    // plan to the audit schema it was derived from; requires_plan_confirmation
    // is the hardcoded promise that a plan is never self-applying.
    static let projectCleanupPlan = OperationOracle(
        .projectCleanupPlan,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(
                key: "schema",
                expected: .string("logic_pro_mcp_project_cleanup_plan.v1")
            ),
            .valueEquals(
                key: "source_audit_schema",
                expected: .string("logic_pro_mcp_project_audit.v1")
            ),
            .valueEquals(key: "read_only", expected: .bool(true)),
            .valueEquals(key: "requires_plan_confirmation", expected: .bool(true)),
            .enumMember(key: "status", allowed: ["ok", "degraded", "failed"]),
            .typedField(key: "steps", type: .array),
        ]
    )

    // MARK: - audio

    // AudioAnalyzer.Result CodingKeys. NOTE: unreachable under the current
    // probe (empty params → unsafe_path failure body), but the oracle pins the
    // real success contract.
    static let audioAnalyzeFile = OperationOracle(
        .audioAnalyzeFile,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_audio_analysis.v1")),
            // {pass, warn} only — NOT fail. AudioDispatcher sets
            // `isError: result.verification.status == .fail`, so a fail body
            // always arrives with isError and the runner classifies it
            // notQualified before this oracle is consulted. Accepting "fail"
            // could therefore only ever launder a failed analysis into a
            // semantic pass; a `warn` is a completed measurement with caveats,
            // a `fail` is not a measurement at all.
            .enumMember(key: "verification.status", allowed: ["pass", "warn"]),
            .typedField(key: "verification.reasons", type: .array),
            .typedField(key: "exists", type: .bool),
            .numericRange(key: "duration_seconds", min: 0, max: 86_400),
            .numericRange(key: "sample_rate", min: 0, max: 768_000),
            .numericRange(key: "channel_count", min: 0, max: 512),
            // dBFS is a negative-or-zero log scale; a positive peak from this
            // analyzer would mean the measurement, not the file, is wrong.
            .numericRange(key: "peak_dbfs", min: -200, max: 0),
            .numericRange(key: "silence_ratio", min: 0, max: 1),
        ]
    )

    // AudioDispatcher `spectralAnalysisResult` encodes SpectralAnalysisResult
    // unchanged. A complete extraction always has the default log-band grid;
    // AudioFeatureExtractionEngine.Config pins its centres to 20...20,000 Hz.
    static let audioAnalyzeSpectrum = OperationOracle(
        .audioAnalyzeSpectrum,
        strength: .shapeAndDomain,
        constraints: [
            .typedField(key: "analysisRef", type: .string),
            .typedField(key: "artifactFingerprint", type: .string),
            .typedField(key: "sampleRate", type: .number),
            .typedField(key: "channelCount", type: .number),
            .typedField(key: "durationSeconds", type: .number),
            .typedField(key: "windowsAnalyzed", type: .number),
            .enumMember(
                key: "channelMode",
                allowed: ["mono", "stereo_energy_average", "multichannel_energy_average"]
            ),
            .valueEquals(key: "complete", expected: .bool(true)),
            .nonEmptyArray(key: "bands"),
            .numericRange(key: "bands.0.centerHz", min: 20, max: 20_000),
            .typedField(key: "bands.0.energyDb", type: .number),
            .typedField(key: "resonances", type: .array),
            .typedField(key: "frequencyPeaks", type: .array),
            .enumMember(key: "classification", allowed: ["vocal", "drums", "bass", "fullMix", "unknown"]),
            .numericRange(key: "confidence", min: 0, max: 1),
        ]
    )

    // AudioDispatcher `eqRecommendationResult` encodes EQBandRecommendation
    // directly. The default six-bands-per-octave grid keeps a detected
    // resonance's Q at or below 10; recommendEQ makes gainDb non-positive.
    static let audioRecommendEQ = OperationOracle(
        .audioRecommendEQ,
        strength: .shapeAndDomain,
        constraints: [
            .nonEmptyArray(key: "bands"),
            .numericRange(key: "bands.0.centerHz", min: 20, max: 20_000),
            .typedField(key: "bands.0.gainDb", type: .number),
            .numericRange(key: "bands.0.q", min: 0, max: 10),
            .valueEquals(key: "bands.0.reason", expected: .string("resonance_cut")),
        ]
    )

    // MARK: - midi

    // CoreMIDIChannel `listMIDIPortsJSON` → {"sources":[String],
    // "destinations":[String]}. The `logic://midi/ports` resource routes the
    // SAME midi.list_ports operation and serves the channel's message verbatim
    // (ResourceHandlers+StateReaders), so response and readback are equal by
    // construction — the strongest available check for a body with no constants.
    static let midiListPorts = OperationOracle(
        custom: .midiListPorts,
        reason: """
            The body has no constant-valued field (both keys are \
            environment-dependent string arrays), so no declarative VALUE \
            constraint exists, and the constraint model cannot bind two \
            payloads at once. HONEST SCOPE OF THIS CHECK: the readback resource \
            re-invokes the SAME midi.list_ports handler and serves its message \
            verbatim, so agreement proves same-handler echo and transport \
            consistency — it is NOT an independent readback and must not be \
            read as one. It still catches truncation, reordering, and \
            serialization damage between the two reads. No truly independent \
            MIDI probe exists today; Phase B may add a CoreMIDI-direct probe to \
            make this a real cross-check.
            """
    ) { responseData, readbackData in
        guard let response = JSONInspector.parse(responseData) as? [String: Any],
              let readback = JSONInspector.parse(readbackData) as? [String: Any] else {
            return false
        }
        // A degraded resource read answers {"message":…} or {"error":…}; that is
        // not an independent confirmation of the port lists.
        guard let responseSources = response["sources"] as? [String],
              let responseDestinations = response["destinations"] as? [String],
              let readbackSources = readback["sources"] as? [String],
              let readbackDestinations = readback["destinations"] as? [String] else {
            return false
        }
        return responseSources == readbackSources
            && responseDestinations == readbackDestinations
    }

    // MARK: - tracks

    // LibraryAccessor.Inventory → {categories, presetsByCategory,
    // currentCategory?, currentPreset?}. The `logic://library/inventory`
    // resource wraps the cached scan in a T7 envelope under "data".
    static let tracksListLibrary = OperationOracle(
        custom: .tracksListLibrary,
        reason: """
            LibraryAccessor.Inventory has no constant-valued field — all four \
            keys are environment-dependent — so no declarative VALUE constraint \
            exists. The load-bearing check is the internal consistency of the \
            inventory (every advertised category must actually carry a preset \
            list) plus agreement with the independent inventory resource read, \
            neither of which the constraint model can express.
            """
    ) { responseData, readbackData in
        guard let response = JSONInspector.parse(responseData) as? [String: Any],
              let categories = response["categories"] as? [String],
              let presetsByCategory = response["presetsByCategory"] as? [String: Any] else {
            return false
        }
        // A zero-category inventory would make the checks below vacuously true
        // (`[].allSatisfy` is true, and two empty sets always agree). "I read
        // nothing and it was all consistent" is not a semantic pass.
        guard !categories.isEmpty else { return false }
        // An inventory that advertises a category it cannot enumerate presets
        // for is lying about what it read — and the preset list must actually
        // be a list of preset names, not merely some value under that key.
        guard categories.allSatisfy({ presetsByCategory[$0] as? [String] != nil }) else {
            return false
        }
        // Fail closed on the readback. A degraded resource read ({"error":…},
        // a cache miss {"cached":false,…}, or a non-object body) carries no
        // inventory to compare against — and an internal-consistency-only pass
        // would report `readback.verified == true` on evidence that contributed
        // nothing. Without a usable independent read there is no semantic
        // verification to claim.
        guard let readback = JSONInspector.parse(readbackData) as? [String: Any],
              let data = readback["data"] as? [String: Any],
              let readbackCategories = data["categories"] as? [String],
              !readbackCategories.isEmpty else {
            return false
        }
        return Set(categories) == Set(readbackCategories)
    }

    // AccessibilityChannel+Library `encodeLibraryRoot` →
    // {"source": <tag>, "root": LibraryRoot}. The probe sends empty params, so
    // the mode defaults to `disk`; a disk scan that throws silently falls back
    // to the live panel scan and re-tags the source, so both tags are legal.
    static let tracksScanLibrary = OperationOracle(
        .tracksScanLibrary,
        strength: .shapeAndDomain,
        constraints: [
            .enumMember(key: "source", allowed: ["disk", "panel"]),
            .typedField(key: "root", type: .object),
            .typedField(key: "root.categories", type: .array),
            .numericRange(key: "root.nodeCount", min: 0, max: 10_000_000),
            .numericRange(key: "root.leafCount", min: 0, max: 10_000_000),
            .numericRange(key: "root.folderCount", min: 0, max: 10_000_000),
            .numericRange(key: "root.scanDurationMs", min: 0, max: 3_600_000),
            .typedField(key: "root.selectionRestored", type: .bool),
        ]
    )

    // AccessibilityChannel+Library `ResolvePathResponse` (nils omitted).
    // NOTE: unreachable under the current probe (empty params → the dispatcher's
    // `path.isEmpty` gate answers invalid_params). The cold-cache success body
    // is {"exists":false,"reason":…}, so only `exists` is always present.
    static let tracksResolvePath = OperationOracle(
        custom: .tracksResolvePath,
        reason: """
            The success contract guarantees exactly one field — `exists: Bool` — \
            because ResolvePathResponse omits every nil. No constant-valued \
            field exists, and a constraint on `exists` could only restate its \
            type. The load-bearing semantics are CONDITIONAL: a hit must name \
            what it matched and how it was classified; a miss must say why. The \
            constraint model has no implication case, so the conditional lives \
            in the closure.
            """
    ) { responseData, _ in
        guard let response = JSONInspector.parse(responseData) as? [String: Any],
              let exists = response["exists"], JSONInspector.isBoolean(exists) else {
            return false
        }
        guard (exists as? NSNumber)?.boolValue == true else {
            // A miss must explain itself rather than answering a bare false.
            return (response["reason"] as? String)?.isEmpty == false
        }
        // A hit must name the matched path and classify the node it found.
        guard let matchedPath = response["matchedPath"] as? String,
              !matchedPath.isEmpty,
              let kind = response["kind"] as? String else {
            return false
        }
        // LibraryNodeKind raw values.
        return ["folder", "leaf", "truncated", "probeTimeout", "cycle"].contains(kind)
    }

    // AccessibilityChannel+Library `runLivePluginPresetScan` → PluginPresetCache.
    // schemaVersion/pluginName/pluginIdentifier/contentHash are hardcoded at the
    // encode site; measuredSubmenuOpenDelayMs echoes the settle delay, which the
    // dispatcher defaults to 250 when the probe omits it — an echo the oracle
    // pins so a handler that ignores the parameter is caught.
    static let tracksScanPluginPresets = OperationOracle(
        .tracksScanPluginPresets,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schemaVersion", expected: .number(1)),
            .valueEquals(key: "pluginName", expected: .string("(focused-plugin)")),
            .valueEquals(key: "contentHash", expected: .string("(deferred)")),
            .valueEquals(key: "measuredSubmenuOpenDelayMs", expected: .number(250)),
            .typedField(key: "root", type: .object),
            .numericRange(key: "nodeCount", min: 0, max: 10_000_000),
            .numericRange(key: "leafCount", min: 0, max: 10_000_000),
            .numericRange(key: "scanDurationMs", min: 0, max: 3_600_000),
        ]
    )

    // MARK: - #373 Phase B1 — verified-write safe-mutation oracles

    // Each composes `SafeMutationOracle.verifiedEnvelope` (State A + verified +
    // success — the honest-contract proof the write was CONFIRMED) with the
    // operation's own semantic invariant, derived by READING the handler and
    // pinning what its `encodeStateA` extras actually emit. The envelope is
    // always FIRST, so no oracle asserts what changed before proving it was
    // verified.

    // mixer

    // AccessibilityChannel+Mixer `defaultSetMixerValue` (target .volume) →
    // encodeStateA(baseExtras). WHY NOT fieldsEqual(requested, observed): this
    // fader is driven by AXIncrement/AXDecrement in ~10-raw-unit DETENTS, so the
    // handler converges to the NEAREST representable detent — `observed` is
    // deliberately ≠ `requested` in general. The write-LANDED proof is the
    // handler's OWN State-A gate, `abs(observedRaw − targetRaw) <= 6.0`
    // (AccessibilityChannel+Mixer.swift line 174), pinned as `.numericNear` on the
    // raw AX values it emits: `observed_raw` is the achieved slider position and
    // `target_raw` the REQUESTED value mapped to raw — DIFFERENT sources, so this
    // is a genuine request↔readback bound, not a same-source echo. (The prior
    // `fieldsEqual(observed, observed_after)` was a tautology — both keys are the
    // same post-write read-back.) Plus the hardcoded write/verify method echoes;
    // requested is domain-pinned; observed is shape-typed only.
    static let mixerSetVolume = SafeMutationOracle.oracle(
        .mixerSetVolume,
        semantics: [
            .valueEquals(key: "operation", expected: .string("mixer.set_volume")),
            .valueEquals(key: "control", expected: .string("volume")),
            .valueEquals(key: "verify_source", expected: .string("ax_slider")),
            .valueEquals(key: "write_method", expected: .string("ax_increment_decrement")),
            .numericNear(keyA: "observed_raw", keyB: "target_raw", within: .absolute(6.0)),
            .numericRange(key: "requested", min: 0, max: 1),
            .typedField(key: "observed", type: .number),
        ]
    )

    // AccessibilityChannel+Mixer `defaultSetMixerValue` (target .pan) — same
    // detent-quantized AX-slider path as set_volume (the `<= 6.0` raw convergence
    // gate is shared code); `control` is "pan" and requested is the centered −1..1.
    static let mixerSetPan = SafeMutationOracle.oracle(
        .mixerSetPan,
        semantics: [
            .valueEquals(key: "operation", expected: .string("mixer.set_pan")),
            .valueEquals(key: "control", expected: .string("pan")),
            .valueEquals(key: "verify_source", expected: .string("ax_slider")),
            .valueEquals(key: "write_method", expected: .string("ax_increment_decrement")),
            .numericNear(keyA: "observed_raw", keyB: "target_raw", within: .absolute(6.0)),
            .numericRange(key: "requested", min: -1, max: 1),
            .typedField(key: "observed", type: .number),
        ]
    )

    // MCUChannel `executeSetMasterVolume` → encodeStateA(extras). The master fader
    // has NO AX track-header equivalent (#142), so an MCU echo on strip 8 is the
    // ONLY readback and State A gates on `abs(observed − value) <= 2.0/16383.0`
    // (14-bit echo resolution; MCUChannel.swift line 509). That handler tolerance
    // is pinned as `.numericNear(observed, requested, 2/16383)` — a genuine
    // request↔echo bound (observed is the decoded MCU echo, requested the input) —
    // alongside the constant `track:"master"` (a STRING, not an index — uniquely
    // marks the master-strip write) and `readback_source:"mcu_echo"`.
    static let mixerSetMasterVolume = SafeMutationOracle.oracle(
        .mixerSetMasterVolume,
        semantics: [
            .valueEquals(key: "track", expected: .string("master")),
            .valueEquals(key: "readback_source", expected: .string("mcu_echo")),
            .numericNear(keyA: "observed", keyB: "requested", within: .absolute(2.0 / 16383.0)),
            .numericRange(key: "requested", min: 0, max: 1),
        ]
    )

    // tracks

    // AccessibilityChannel+Tracks `defaultSelectTrack` → encodeStateA(base +
    // observed). base = {requested: index, selected: index}; State A merges
    // observed: index — so all THREE are the same input `index`, re-echoed. The
    // real verification is STRUCTURAL: the handler emits State A only in the
    // `.verified` switch case (the AX readback confirmed selection landed on the
    // requested track), so the ENVELOPE is the load-bearing proof. The
    // requested/selected/observed equalities are therefore ECHO-INTEGRITY (the
    // wire consistently carried the one index; a serialization that corrupted one
    // side is caught), NOT a request↔readback semantic pin — the payload carries
    // no independent readback value to pin. requested is domain-pinned.
    static let tracksSelect = SafeMutationOracle.oracle(
        .tracksSelect,
        semantics: [
            // Echo-integrity (same-source index), not a write-verification claim.
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .fieldsEqual(keyA: "selected", keyB: "observed"),
            .numericRange(key: "requested", min: 0, max: 100_000),
        ]
    )

    // AccessibilityChannel+Tracks `defaultRenameTrack` → encodeStateA(baseExtras
    // + observed + via). State A is reached ONLY when the AX read-back name equals
    // the requested name (`observed == truncatedName == requested`), so
    // requested==observed is the load-bearing invariant (both strings; the keys
    // are `requested`/`observed`, NOT `requested_name`/`observed_name` — pinned by
    // reading the handler). `via` records the write path; `track` the index.
    static let tracksRename = SafeMutationOracle.oracle(
        .tracksRename,
        semantics: [
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "track", type: .number),
            .typedField(key: "via", type: .string),
        ]
    )

    /// The `defaultSetTrackToggle` coordinate-free actuator rungs — the
    /// `action` a State-A toggle records as the path that actually landed the
    /// write (#106 / ADR-001: the former value-write / HID `mouse-click` rungs
    /// are removed). `no-op` = already at desired (toggle-from-read); `press` =
    /// AXPress on the checkbox; `keyboard-mute` / `keyboard-solo` /
    /// `keyboard-arm` = exclusive-select then a CGEvent key command. Pinned as a
    /// domain so a toggle claiming an unknown strategy is caught.
    static let trackToggleActions = [
        "no-op", "press", "keyboard-mute", "keyboard-solo", "keyboard-arm",
    ]

    // AccessibilityChannel+Tracks `defaultSetTrackToggle` (button "Mute") →
    // encodeStateA(baseExtras + observed + action). The handler emits
    // `observed: desired` — the SAME input value as `requested: desired` — so
    // requested==observed is ECHO-INTEGRITY, not a readback pin: the real readback
    // is STRUCTURAL (State A is reached only when `pollMatched` confirmed the AX
    // value equals `desired`), carried by the envelope. The NON-tautological
    // content is the constant `button` (which control), `verification_source` (how
    // it was read), and `action` (which write strategy landed — a genuine effect
    // record).
    static let tracksMute = SafeMutationOracle.oracle(
        .tracksMute,
        semantics: [
            .valueEquals(key: "button", expected: .string("Mute")),
            .valueEquals(key: "verification_source", expected: .string("ax_value")),
            .enumMember(key: "action", allowed: trackToggleActions),
            // Echo-integrity (same-source desired), not a write-verification claim.
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "track", type: .number),
        ]
    )

    // AccessibilityChannel+Tracks `defaultSetTrackToggle` (button "Solo") — same
    // echo-integrity + genuine `action`/`button`/`verification_source` shape as mute.
    static let tracksSolo = SafeMutationOracle.oracle(
        .tracksSolo,
        semantics: [
            .valueEquals(key: "button", expected: .string("Solo")),
            .valueEquals(key: "verification_source", expected: .string("ax_value")),
            .enumMember(key: "action", allowed: trackToggleActions),
            // Echo-integrity (same-source desired), not a write-verification claim.
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "track", type: .number),
        ]
    )

    // AccessibilityChannel+Tracks `defaultSetTrackToggle` (button "Record" — the
    // record-ARM checkbox; Logic labels the arm control "Record").
    static let tracksArm = SafeMutationOracle.oracle(
        .tracksArm,
        semantics: [
            .valueEquals(key: "button", expected: .string("Record")),
            .valueEquals(key: "verification_source", expected: .string("ax_value")),
            .enumMember(key: "action", allowed: trackToggleActions),
            // Echo-integrity (same-source desired), not a write-verification claim.
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "track", type: .number),
        ]
    )

    // TrackDispatcher `arm_only` → encodeStateA(armOnlyExtras(...)). arm_only's
    // whole effect is "disarm every OTHER track + arm the target". It reaches
    // State A only when the target arm is verified AND the disarm sweep left no
    // failures/uncertainties — the dispatcher passes armedSuccess:true with
    // failedDisarm:[] and unverifiedDisarm:[]. The MULTI-TRACK gate is pinned via
    // `.emptyArray` on both lists (FIX 4) so the sweep effect is checked, not just
    // the target arm. NOTE requested_enabled==observed_enabled and
    // armed==target_track are ECHO-INTEGRITY: observed_enabled is forwarded from
    // set_arm's `observed`, itself a re-echo of `desired` (see tracks.mute), and
    // armed/target_track are the same index — neither is an independent readback.
    // The genuine content is the op identity, armedSuccess, the always-arm intent
    // (requested_enabled:true), and the empty failure lists. verification_source
    // is NOT pinned — it is channel-dependent (forwarded from set_arm).
    static let tracksArmOnly = SafeMutationOracle.oracle(
        .tracksArmOnly,
        semantics: [
            .valueEquals(key: "operation", expected: .string("track.arm_only")),
            .valueEquals(key: "armedSuccess", expected: .bool(true)),
            .valueEquals(key: "requested_enabled", expected: .bool(true)),
            // Multi-track gate: the disarm sweep left nothing failed or unverified.
            .emptyArray(key: "failedDisarm"),
            .emptyArray(key: "unverifiedDisarm"),
            // Echo-integrity (forwarded/same-source), not a readback pin.
            .fieldsEqual(keyA: "requested_enabled", keyB: "observed_enabled"),
            .fieldsEqual(keyA: "armed", keyB: "target_track"),
        ]
    )

    // MCUChannel `executeAutomation` → encodeStateA(extras). BOTH State-A branches
    // (already-in-mode fast path, and the write path) emit function:"set_automation",
    // the requested `mode`, and `observed_mode` == requested mode (State A gates on
    // observedMode == requestedMode). The write-phase flags differ between the two
    // branches, so ONLY the common keys are pinned: the hardcoded function echo,
    // the legal mode domain, and the load-bearing mode==observed_mode agreement.
    static let tracksSetAutomation = SafeMutationOracle.oracle(
        .tracksSetAutomation,
        semantics: [
            .valueEquals(key: "function", expected: .string("set_automation")),
            .enumMember(key: "mode", allowed: ["read", "write", "touch", "latch", "trim"]),
            .fieldsEqual(keyA: "mode", keyB: "observed_mode"),
        ]
    )

    // AccessibilityChannel+Library `setTrackInstrument` → encodeStateA(base +
    // observed/observed_patch_name + verify_source + readback_state:"verified").
    // State A is reached ONLY when the Library panel's selected-preset read-back
    // equals the requested preset (`observed == preset`), so requested==observed
    // is the load-bearing invariant (base sets requested==preset and
    // observed_patch_name==observed). verify_source/readback_state are the
    // hardcoded honest-read markers.
    static let tracksSetInstrument = SafeMutationOracle.oracle(
        .tracksSetInstrument,
        semantics: [
            .valueEquals(key: "verify_source", expected: .string("library_selected_children")),
            .valueEquals(key: "readback_state", expected: .string("verified")),
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .fieldsEqual(keyA: "preset", keyB: "observed_patch_name"),
        ]
    )

    // plugins

    // AccessibilityChannel+VerifiedPlugins `defaultSetParamVerified` →
    // encodeV2StateA(extras). HC v2 (the verified-plugin superset): the envelope
    // additionally carries `hc_schema:2`, pinned here. State A is the tolerance
    // gate `abs(after − requested) <= tolerance` (VerifiedPlugins line 1056), and
    // `tolerance` is PER-PARAMETER in the parameter's OWN unit (0..1 for some
    // controls, 0..100 for others — e.g. Compressor Threshold, tolerance 1.0), so
    // no single constant could bound it. It is pinned as
    // `.numericNear(observed_normalized, requested_normalized, .field("tolerance"))`
    // — reading the bound from the payload's OWN emitted tolerance, the faithful
    // request↔readback proof (observed_normalized is the achieved slider read,
    // requested_normalized the input). Plus the hardcoded same-surface
    // write/verify (no cross-surface laundering), display_unit, operation
    // identity, and target_identity/param shapes.
    static let pluginsSetParamVerified = SafeMutationOracle.oracle(
        .pluginsSetParamVerified,
        semantics: [
            .valueEquals(key: "hc_schema", expected: .number(2)),
            .valueEquals(key: "operation", expected: .string("logic_plugins.set_param_verified")),
            .valueEquals(key: "write_source", expected: .string("ax_plugin_window")),
            .valueEquals(key: "verify_source", expected: .string("ax_plugin_window")),
            .valueEquals(key: "display_unit", expected: .string("%")),
            .numericNear(
                keyA: "observed_normalized",
                keyB: "requested_normalized",
                within: .field("tolerance")
            ),
            .typedField(key: "target_identity", type: .object),
            .typedField(key: "param", type: .string),
        ]
    )

    // MARK: - #373 Phase B2 — transport safe-mutation oracles

    // Each composes `SafeMutationOracle.verifiedEnvelope` (State A + verified +
    // success) with the op's own invariant, derived by READING its dispatcher/
    // channel handler. The envelope is always FIRST, so no oracle asserts what
    // changed before proving it was verified.
    //
    // transport

    /// The control-bar click strategies a transport checkbox toggle records as the
    /// `action` that landed the write, from
    /// `AccessibilityChannel+Transport.controlBarClickStrategies`. The ADR-001
    /// coordinate ban reduced that ladder to AXPress/AXConfirm only — the former
    /// HID `mouse-click` rung was removed and no handler can emit it — so the domain
    /// is exactly `axpress`/`axconfirm`. Pinned as a closed set so a toggle claiming
    /// an unknown strategy (including a regression that re-introduces the banned
    /// mouse-click) is caught.
    static let controlBarClickActions = ["axpress", "axconfirm"]

    // TransportDispatcher `handleVerifiedTransportCommand(.play)` → encodeStateA.
    // BOTH State-A branches (already-playing fast path, and the post-write poll)
    // emit `operation:"transport.play"`, `verify_source:"transport_state"`, and an
    // `observed_after` transportStateSummary whose `isPlaying == true` (State A is
    // reached ONLY when `action.matches(observed)`, i.e. the readback showed
    // playback). `observed_after.isPlaying == true` is the GENUINE invariant — it
    // relates the AX transport readback to the operation's target semantics, NOT a
    // same-source echo. `write_attempted`/`poll_attempts` differ per branch and
    // are not pinned.
    static let transportPlay = SafeMutationOracle.oracle(
        .transportPlay,
        semantics: [
            .valueEquals(key: "operation", expected: .string("transport.play")),
            .valueEquals(key: "verify_source", expected: .string("transport_state")),
            .valueEquals(key: "observed_after.isPlaying", expected: .bool(true)),
        ]
    )

    // TransportDispatcher `handleVerifiedTransportCommand(.record)` — same paths as
    // play, but the State-A gate is `action.matches` = `isPlaying && isRecording`,
    // so the `observed_after` summary shows BOTH true. Both readback flags are
    // pinned (the genuine "recording confirmed" invariant); `observed_after` is an
    // independent AX read, so these are readback semantics, not echoes.
    static let transportRecord = SafeMutationOracle.oracle(
        .transportRecord,
        semantics: [
            .valueEquals(key: "operation", expected: .string("transport.record")),
            .valueEquals(key: "verify_source", expected: .string("transport_state")),
            .valueEquals(key: "observed_after.isPlaying", expected: .bool(true)),
            .valueEquals(key: "observed_after.isRecording", expected: .bool(true)),
        ]
    )

    // TransportDispatcher `verifiedStopResult` → encodeStateA. Its TWO State-A
    // branches diverge in shape: the already-stopped fast path emits
    // `verify_source:"transport_state"` + a nested `observed_after`/`observed_before`
    // transportStateSummary, while the post-write path (`stopObservedExtras`) emits
    // `verify_source:"ax_transport_state"` + FLAT `observed_isPlaying`/… keys. The
    // only universally-present values are the two hardcoded constants
    // `operation:"transport.stop"` and `requested_state:"stopped"`, plus
    // `verify_source` (one of two legal verified-stop provenances — pinned as an
    // enum so an unknown source is caught). The load-bearing "it actually stopped"
    // proof is STRUCTURAL: State A is reached only when the readback showed
    // not-playing/not-recording; the envelope carries that. (Like tracks.select /
    // tracks.set_automation, only the common keys are declaratively pinnable
    // because the two branches emit different readback keys.)
    static let transportStop = SafeMutationOracle.oracle(
        .transportStop,
        semantics: [
            .valueEquals(key: "operation", expected: .string("transport.stop")),
            .valueEquals(key: "requested_state", expected: .string("stopped")),
            .enumMember(key: "verify_source", allowed: ["transport_state", "ax_transport_state"]),
        ]
    )

    // TransportDispatcher `verifiedPauseResult` → encodeStateA. Both State-A
    // branches (already-paused fast path, post-write path) emit the SAME three
    // constants: `operation:"transport.pause"`, `requested_state:"paused"`,
    // `verify_source:"transport_state"` (pause never uses the ax_transport_state
    // tag stop's write path does). Their readback keys differ (nested
    // `observed_after` vs flat `observed_isPlaying`), so — as with stop — the
    // stopped-confirmation is structural (envelope), and only the shared constants
    // are declaratively pinned.
    static let transportPause = SafeMutationOracle.oracle(
        .transportPause,
        semantics: [
            .valueEquals(key: "operation", expected: .string("transport.pause")),
            .valueEquals(key: "requested_state", expected: .string("paused")),
            .valueEquals(key: "verify_source", expected: .string("transport_state")),
        ]
    )

    // AccessibilityChannel+Transport `clickControlBarCheckbox` (Cycle) →
    // encodeStateA. State A is reached ONLY when the AX read-back value flipped
    // (`waitForControlBarCheckboxValue { $0 != before }`), and the envelope carries
    // `previous:before` + `observed:after` from TWO independent AX reads — so
    // `observed == !previous` (`.booleanFlipped`) is the GENUINE "the toggle
    // changed state" invariant, not a same-source echo. Plus the hardcoded
    // `button:"Cycle"` / `control:"사이클"` identity and the click-strategy `action`.
    // Single State-A branch (the dispatcher does a bare `toolTextResult`, no
    // finalize), so the flip pair is universal here.
    static let transportToggleCycle = SafeMutationOracle.oracle(
        .transportToggleCycle,
        semantics: [
            .valueEquals(key: "button", expected: .string("Cycle")),
            .valueEquals(key: "control", expected: .string("사이클")),
            .booleanFlipped(keyA: "observed", keyB: "previous"),
            .enumMember(key: "action", allowed: controlBarClickActions),
        ]
    )

    // AccessibilityChannel+Transport `clickControlBarCheckbox` (Count In) — same
    // single-branch flip shape as toggle_cycle; `button:"Count In"`,
    // `control:"카운트 인"`.
    static let transportToggleCountIn = SafeMutationOracle.oracle(
        .transportToggleCountIn,
        semantics: [
            .valueEquals(key: "button", expected: .string("Count In")),
            .valueEquals(key: "control", expected: .string("카운트 인")),
            .booleanFlipped(keyA: "observed", keyB: "previous"),
            .enumMember(key: "action", allowed: controlBarClickActions),
        ]
    )

    // AccessibilityChannel+Transport `defaultToggleAutopunch` → encodeStateA. Its
    // single State-A branch fires only when `after == requested == !before`, and
    // the envelope carries `previous:before` + `observed:after` — so
    // `observed == !previous` (`.booleanFlipped`) is the genuine flip. Plus the
    // hardcoded `operation:"transport.toggle_autopunch"`, `button:"Autopunch"`, and
    // `action:"axpress"` (autopunch uses AXPress exclusively, not the click-strategy
    // ladder). `control` is a locale LabelSet (`transportAutopunchControl.canonical`)
    // so it is not pinned.
    static let transportToggleAutopunch = SafeMutationOracle.oracle(
        .transportToggleAutopunch,
        semantics: [
            .valueEquals(key: "operation", expected: .string("transport.toggle_autopunch")),
            .valueEquals(key: "button", expected: .string("Autopunch")),
            .valueEquals(key: "action", expected: .string("axpress")),
            .booleanFlipped(keyA: "observed", keyB: "previous"),
        ]
    )

    // toggle_metronome is the one B2 toggle whose verified State A is NOT a single
    // shape. It routes `[.accessibility, .midiKeyCommands, .cgEvent]` and the
    // dispatcher RE-VERIFIES a send-only channel via `finalizeToggleMetronomeResult`
    // (an independent transport-state read). The reachable State-A shapes share NO
    // non-envelope key:
    //   * AX-verified (`clickControlBarCheckbox`): flip on `observed`/`previous`,
    //     plus `button:"Metronome"`/`control:"메트로놈 클릭"`/`action` — and NO
    //     `operation`/`verification_source`/`*_enabled`.
    //   * dispatcher-verified (the keycmd/cgEvent State B confirmed by finalize when
    //     the transport-state metronome flag flipped): flip on
    //     `observed_enabled`/`previous_enabled` + `verification_source:"transport_state"`
    //     — and the keycmd/cgEvent State B carries NO `button`/`control`/`action`
    //     (keycmd emits `operation`/`method`/`cc`; cgEvent emits `operation`/`method`).
    // So pinning `button`/`control`/`action` (or either flip pair) would FALSE-RED
    // the other genuine State A — e.g. an AX-control-absent, keycmd-bound setup in
    // the #284 matrix emits the dispatcher-verified shape, which has none of those
    // keys. The oracle therefore pins only the channel-independent verified envelope
    // (State A + verified + success). The "metronome actually toggled" proof is
    // STRUCTURAL, exactly as for transport.stop / transport.pause: EVERY path
    // reaches State A only on a CONFIRMED flip — AX via
    // `waitForControlBarCheckboxValue { $0 != before }`, dispatcher via
    // `beforeTransport.isMetronomeEnabled != afterTransport.isMetronomeEnabled` — so
    // a no-op is honest State B (or C) and the envelope rejects it. The dedicated
    // engine test proves the relaxed oracle accepts BOTH channel shapes yet still
    // rejects a no-op / failure, so it is not vacuous.
    static let transportToggleMetronome = SafeMutationOracle.oracle(
        .transportToggleMetronome,
        semantics: []
    )

    // AccessibilityChannel+Transport `defaultSetTempo` → encodeStateA. All three
    // State-A branches (`via` = slider / slider-increment / slider-value-nudge)
    // gate on `abs(observed − requested) < 1.0` (the hardcoded 1-BPM convergence
    // tolerance) and emit `requested` (the input BPM) + `observed` (the slider AX
    // read). Pinned as `.numericNear(observed, requested, 1.0)` — a genuine
    // request↔readback bound (the oracle's `<=` is a hair looser than the handler's
    // strict `<`, which cannot false-pass a realistic verified write). `requested`
    // is domain-pinned to Logic's 5..990 tempo range (handler guard), and `via` is
    // the write-path enum (which slider strategy landed).
    static let transportSetTempo = SafeMutationOracle.oracle(
        .transportSetTempo,
        semantics: [
            .numericNear(keyA: "observed", keyB: "requested", within: .absolute(1.0)),
            .numericRange(key: "requested", min: 5, max: 990),
            .enumMember(key: "via", allowed: ["slider", "slider-increment", "slider-value-nudge"]),
        ]
    )

    // TransportDispatcher `finalizeGotoPositionResult` → encodeStateA. State A is
    // reached ONLY when `!requested.contains(":") && observedTransport.position ==
    // requested`, where `requested` is the requested bar-position string and
    // `observed` is read from an INDEPENDENT `transport.get_state` AX read — so
    // `.fieldsEqual(requested, observed)` is a genuine request↔readback pin (the
    // playhead landed exactly where asked). Plus the hardcoded
    // `verification_source:"transport_state"` and the shape of the SMPTE echo.
    static let transportGotoPosition = SafeMutationOracle.oracle(
        .transportGotoPosition,
        semantics: [
            .valueEquals(key: "verification_source", expected: .string("transport_state")),
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "observed_time_position", type: .string),
        ]
    )

    // MARK: - #373 Phase B2 — navigate safe-mutation oracles

    // NavigateDispatcher `goto_bar` routes `transport.goto_position` and runs the
    // SAME `finalizeGotoPositionResult` as transport.goto_position, so its State A
    // is identical: `requested == observed` playhead position (request↔readback)
    // plus `verification_source:"transport_state"`.
    static let navigateGotoBar = SafeMutationOracle.oracle(
        .navigateGotoBar,
        semantics: [
            .valueEquals(key: "verification_source", expected: .string("transport_state")),
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "observed_time_position", type: .string),
        ]
    )

    // NavigateDispatcher `goto_marker` resolves the target marker from cache and
    // routes `transport.goto_position` with its `position`, then runs
    // `finalizeGotoPositionResult` — so the verified State A is the same
    // `requested == observed` (the marker's position landed on the playhead) plus
    // `verification_source:"transport_state"`. A non-canonical marker additionally
    // carries `marker_position_uncertain`/`marker_position_source` (merged by
    // `mergeMarkerUncertainty`); those are branch-dependent and NOT pinned so a
    // canonical-marker State A is not false-failed.
    static let navigateGotoMarker = SafeMutationOracle.oracle(
        .navigateGotoMarker,
        semantics: [
            .valueEquals(key: "verification_source", expected: .string("transport_state")),
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "observed_time_position", type: .string),
        ]
    )

    // NavigateDispatcher `finalizeCreateMarkerResult` → encodeStateA. State A is
    // reached only when `afterMarkers.count > beforeMarkers.count` AND (for a named
    // create) `createdMarker.name == requestedName`. The load-bearing invariant is
    // `.fieldsEqual(requested_name, observed_marker_name)` — a genuine
    // request↔readback identity echo: `requested_name` is the input, and
    // `observed_marker_name` is read back from the INDEPENDENT `logic://markers`
    // enumeration after the create. Plus the hardcoded
    // `verification_source:"logic://markers"` (dispatcher) and
    // `operation:"nav.create_marker"` (channel) constants, and the shape of the
    // count-delta / new marker id. This models the NAMED create (the qualification
    // and primary path); an unnamed auto-create is a distinct name-less State-A
    // shape whose `requested_name` is absent, and the count-delta remains the
    // structural creation proof carried by the envelope.
    static let navigateCreateMarker = SafeMutationOracle.oracle(
        .navigateCreateMarker,
        semantics: [
            .valueEquals(key: "verification_source", expected: .string("logic://markers")),
            .valueEquals(key: "operation", expected: .string("nav.create_marker")),
            .fieldsEqual(keyA: "requested_name", keyB: "observed_marker_name"),
            .typedField(key: "observed_marker_id", type: .number),
            .typedField(key: "marker_count_after", type: .number),
            .typedField(key: "marker_count_before", type: .number),
        ]
    )

    // AccessibilityChannel+MarkerDelete `defaultDeleteMarker` is accessibility-only.
    // Its State-A gate is stronger than a count check: it reads the marker list
    // after the delete until two consecutive POSITION multisets settle. State A
    // requires a unique, canonically parsed target position; the expected pre-write
    // positions with one target-position instance removed; the observed positions
    // to equal that expectation; and the count to decrease by one. Each position
    // is length-prefixed before the entries are sorted and joined, so the envelope's
    // strings have unambiguous boundaries and can be checked against both counts.
    // The oracle binds that independently read-back multiset to the
    // request-derived expectation. A shared or synthetic target position is State B:
    // a position occurrence can disappear without identifying which marker it was.
    // Marker names remain only State-B diagnostics because Logic can renumber
    // auto-generated names after deletion.
    static let navigateDeleteMarker = SafeMutationOracle.oracle(
        .navigateDeleteMarker,
        semantics: [
            .valueEquals(key: "operation", expected: .string("nav.delete_marker")),
            .typedField(key: "requested_index", type: .number),
            .typedField(key: "target_name", type: .string),
            .typedField(key: "target_position", type: .string),
            .valueEquals(key: "target_position_unique", expected: .bool(true)),
            .valueEquals(key: "position_evidence_canonical", expected: .bool(true)),
            .typedField(key: "marker_count_before", type: .number),
            .valueEquals(key: "readback_settled", expected: .bool(true)),
            .typedField(key: "marker_count_after", type: .number),
            .lengthPrefixedEntryCountEquals(
                key: "expected_survivor_position_multiset",
                countKey: "marker_count_before",
                offset: -1
            ),
            .lengthPrefixedEntryCountEquals(
                key: "observed_survivor_position_multiset",
                countKey: "marker_count_after",
                offset: 0
            ),
            .fieldsEqual(
                keyA: "expected_survivor_position_multiset",
                keyB: "observed_survivor_position_multiset"
            ),
        ]
    )

    // AccessibilityChannel+Markers `defaultRenameMarker` → encodeStateA. Both
    // State-A branches (the already-named no-op path and the post-write path) emit
    // `operation:"nav.rename_marker"`, `requested_name` (input), and `observed_name`
    // read back from the marker-list enumeration; State A is reached only when
    // `observed_name == requested_name`, so `.fieldsEqual(requested_name,
    // observed_name)` is the genuine request↔readback rename proof. `previous_name`
    // (the pre-rename label) and `index` are shape-pinned. `write_attempted` differs
    // per branch and is not pinned.
    static let navigateRenameMarker = SafeMutationOracle.oracle(
        .navigateRenameMarker,
        semantics: [
            .valueEquals(key: "operation", expected: .string("nav.rename_marker")),
            .fieldsEqual(keyA: "requested_name", keyB: "observed_name"),
            .typedField(key: "index", type: .number),
            .typedField(key: "previous_name", type: .string),
        ]
    )

    // AccessibilityChannel+Transport `defaultSetZoomLevel` (the AX arrange
    // Horizontal-Zoom slider) → encodeStateA, reached via NavigateDispatcher
    // `set_zoom` for in/out/numeric levels (fit routes to the send-only
    // zoom_to_fit). State A gates on `abs(after − target) < 0.02` where `target =
    // (level−1)/9` and `observed:after` is the slider AX read — pinned as
    // `.numericNear(observed, requested, 0.02)`, a genuine request↔readback bound
    // (`requested` carries the computed target). Plus the hardcoded
    // `operation:"nav.set_zoom"`, `axis:"horizontal"`, `verify_source:"ax_zoom_slider"`
    // constants and the 1..10 `level` domain.
    static let navigateSetZoom = SafeMutationOracle.oracle(
        .navigateSetZoom,
        semantics: [
            .valueEquals(key: "operation", expected: .string("nav.set_zoom")),
            .valueEquals(key: "axis", expected: .string("horizontal")),
            .valueEquals(key: "verify_source", expected: .string("ax_zoom_slider")),
            .numericNear(keyA: "observed", keyB: "requested", within: .absolute(0.02)),
            .numericRange(key: "level", min: 1, max: 10),
        ]
    )

    // MARK: - #373 Phase B3 — project safe-mutation oracles

    // Each composes `SafeMutationOracle.verifiedEnvelope` (State A + verified +
    // success) with the op's own invariant, derived by READING its dispatcher/
    // channel handler. The envelope is always FIRST, so no oracle asserts what
    // changed before proving it was verified.
    //
    // project

    // AppleScriptChannel `verifiedSaveResult` (chain [.appleScript, …]; the
    // midiKeyCommands/cgEvent fallbacks are send-only State B, so this is the
    // ONLY State-A shape). State A is reached ONLY when the `.logicx` package mtime
    // advanced past the save start (`wroteThisSave`), which requires a non-empty
    // `document_path` and a readable `observed_mtime` — so those are present in
    // every State A. `verify_source:"file_mtime"` is the hardcoded honest-read
    // marker (the mtime advance IS the verification), and `operation`/`method` are
    // the fixed provenance. The "it actually saved" proof is STRUCTURAL — the
    // handler only reaches State A on a real mtime advance — so, like
    // transport.stop, the envelope + the provenance constants are the pin.
    static let projectSave = SafeMutationOracle.oracle(
        .projectSave,
        semantics: [
            .valueEquals(key: "operation", expected: .string("project.save")),
            .valueEquals(key: "method", expected: .string("applescript")),
            .valueEquals(key: "verify_source", expected: .string("file_mtime")),
            .typedField(key: "document_path", type: .string),
            .typedField(key: "observed_mtime", type: .string),
        ]
    )

    // save_as is the one B3 project op whose verified State A is NOT a single
    // shape. Its chain is [.accessibility, .appleScript] and BOTH channels reach a
    // genuine State A with DISJOINT non-envelope keys:
    //   * AX-dialog (`AccessibilityChannel.saveAsViaAXDialog`): `requested`,
    //     `observed` (the on-disk path confirmed by FileManager.fileExists), and
    //     `via` ∈ {"save-dialog","save-dialog-with-ext"} — and NO `operation`/
    //     `method`/`path`.
    //   * AppleScript (`wrapSaveAsResult`): `operation:"project.save_as"`,
    //     `method:"applescript"`, `path`, `observed` (the confirmed package path),
    //     `observed_mtime` — and NO `requested`/`via`.
    // The requested-side key differs (`requested` vs `path`) and the only shared
    // non-envelope key is `observed` (an environment-dependent path string with no
    // constant), so pinning either shape's keys would FALSE-RED the other genuine
    // State A. The oracle therefore pins only the channel-independent verified
    // envelope (State A + verified + success), exactly as toggle_metronome /
    // transport.stop do when their branches share no key. The "the file was
    // actually written" proof is STRUCTURAL: EVERY path reaches State A only after
    // confirming the package on disk (AX: FileManager.fileExists; AppleScript: mtime
    // advance), so a save that did not write is honest State B/C and the envelope
    // rejects it. The dedicated engine test proves the oracle accepts BOTH channel
    // shapes yet still rejects a State B / State C, so it is not vacuous.
    static let projectSaveAs = SafeMutationOracle.oracle(
        .projectSaveAs,
        semantics: []
    )

    // AccessibilityChannel `openBounceDialogViaMenu` (chain [.accessibility, …];
    // the midiKeyCommands/cgEvent fallbacks are send-only State B, so this is the
    // ONLY State-A shape). CRITICAL semantic: State A here means the Bounce DIALOG
    // OPENED — NOT that a bounce artifact was produced (`bounce_fired:false` is
    // hardcoded and load-bearing: the op deliberately stops at the dialog for the
    // human to choose settings/destination). `requested`/`observed` are both the
    // literal "bounce_dialog_open" (pinned exactly, so a handler that reported the
    // wrong milestone is caught), `dialog_opened:true` is the confirmed effect, and
    // `via:"file-menu"` is the fixed provenance.
    static let projectBounce = SafeMutationOracle.oracle(
        .projectBounce,
        semantics: [
            .valueEquals(key: "operation", expected: .string("project.bounce")),
            .valueEquals(key: "requested", expected: .string("bounce_dialog_open")),
            .valueEquals(key: "observed", expected: .string("bounce_dialog_open")),
            .valueEquals(key: "dialog_opened", expected: .bool(true)),
            .valueEquals(key: "bounce_fired", expected: .bool(false)),
            .valueEquals(key: "via", expected: .string("file-menu")),
        ]
    )

    // MARK: - #373 Phase B3 — tracks safe-mutation oracles

    // AccessibilityChannel+Tracks `verifyTrackCreation` → encodeStateA (chain
    // [.accessibility, …]; the fallbacks are send-only State B, so this is the ONLY
    // State-A shape). State A is reached ONLY when the live AX track-header count
    // INCREASED (`currentCount > beforeCount`), so `observed_delta` (= after −
    // before) is ≥ 1 — the genuine "a new track is present" invariant, pinned as a
    // `.numericRange(min: 1)`. `requested_delta:1` is the create intent,
    // `verification_source:"track_count_delta"` is how it was verified, and
    // `track_type_verification_source:"observed_header"` records that the type
    // came from the newly observed header rather than from the requested menu
    // item. `observed_track_type` is the PER-OP discriminator — the four
    // create_* handlers pass distinct expected types (audio / softwareInstrument
    // / drummer / externalMIDI), so pinning it rejects a create that produced a
    // different observed type.
    private static func createTrackSemantics(observedType: String) -> [OracleConstraint] {
        [
            .valueEquals(key: "requested_delta", expected: .number(1)),
            .valueEquals(key: "verification_source", expected: .string("track_count_delta")),
            .valueEquals(key: "track_type_verification_source", expected: .string("observed_header")),
            .valueEquals(key: "observed_track_type", expected: .string(observedType)),
            .numericRange(key: "observed_delta", min: 1, max: 10_000),
            .typedField(key: "track_count_before", type: .number),
            .typedField(key: "track_count_after", type: .number),
            .typedField(key: "observed_track_index", type: .number),
        ]
    }

    // TrackDispatcher `create_audio` → AccessibilityChannel.createTrackViaMenu with
    // expectedTrackType `.audio` (TrackType.audio.rawValue == "audio").
    static let tracksCreateAudio = SafeMutationOracle.oracle(
        .tracksCreateAudio,
        semantics: createTrackSemantics(observedType: "audio")
    )

    // create_instrument → expectedTrackType `.softwareInstrument`
    // (TrackType.softwareInstrument.rawValue == "software_instrument").
    static let tracksCreateInstrument = SafeMutationOracle.oracle(
        .tracksCreateInstrument,
        semantics: createTrackSemantics(observedType: "software_instrument")
    )

    // create_drummer → expectedTrackType `.drummer` (rawValue == "drummer").
    static let tracksCreateDrummer = SafeMutationOracle.oracle(
        .tracksCreateDrummer,
        semantics: createTrackSemantics(observedType: "drummer")
    )

    // create_external_midi → expectedTrackType `.externalMIDI`
    // (TrackType.externalMIDI.rawValue == "external_midi").
    static let tracksCreateExternalMIDI = SafeMutationOracle.oracle(
        .tracksCreateExternalMIDI,
        semantics: createTrackSemantics(observedType: "external_midi")
    )

    // AccessibilityChannel+Tracks `defaultDeleteTrack` → encodeStateA (chain
    // [.accessibility, …]; fallbacks are send-only State B). State A is reached ONLY
    // when the live AX header count DECREASED (`currentCount < beforeCount`), so
    // `observed_delta` (= after − before) is ≤ −1 — the genuine "the track count
    // was reduced" invariant, pinned as a `.numericRange(max: -1)` so a delete that
    // did not reduce the count cannot pass. `requested_delta:-1` is the delete
    // intent; `menu_clicked` records the menu item that fired. (There is no
    // `verification_source` constant on this path — the count-delta IS the
    // verification, carried by the envelope + the delta range.)
    static let tracksDelete = SafeMutationOracle.oracle(
        .tracksDelete,
        semantics: [
            .valueEquals(key: "requested_delta", expected: .number(-1)),
            .numericRange(key: "observed_delta", min: -10_000, max: -1),
            .typedField(key: "track_count_before", type: .number),
            .typedField(key: "track_count_after", type: .number),
            .typedField(key: "menu_clicked", type: .string),
        ]
    )

    // TrackDispatcher+RecordSequence `verifyRecordSequenceImport` verified payload.
    // NOTE — this op is DELIBERATELY NOT built through `SafeMutationOracle.oracle`:
    // its verified success is hand-assembled via `jsonToolTextResult` and carries
    // `success:true` + `verified:true` but NO `state:"A"` field (it does not call
    // `HonestContract.encodeStateA`). Pinning `state:"A"` would encode a shape the
    // handler never emits, so this oracle pins `success` + `verified` directly as
    // the verified-write proof. The load-bearing semantic is the REGION READBACK
    // match: State A (`.verified`) is reached only when the AX region read back on
    // the created track has `startBar == expected_start_bar` (hardcoded 1) AND
    // `endBar == expected_end_bar`, so `.fieldsEqual(start_bar, expected_start_bar)`
    // + `.fieldsEqual(end_bar, expected_end_bar)` are the genuine "the notes landed
    // in the right region envelope" invariants (start/end are read back, the
    // expected_* are computed). `.fieldsEqual(target_track_index, created_track)`
    // pins that the verified region is on the just-created track, `method:"smf_import"`
    // is the fixed provenance, and `verify_source` is one of the two legal region
    // readback provenances.
    static let tracksRecordSequence = OperationOracle(
        .tracksRecordSequence,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "success", expected: .bool(true)),
            .valueEquals(key: "verified", expected: .bool(true)),
            .valueEquals(key: "method", expected: .string("smf_import")),
            .valueEquals(key: "expected_start_bar", expected: .number(1)),
            .fieldsEqual(keyA: "start_bar", keyB: "expected_start_bar"),
            .fieldsEqual(keyA: "end_bar", keyB: "expected_end_bar"),
            .fieldsEqual(keyA: "target_track_index", keyB: "created_track"),
            .enumMember(key: "verify_source", allowed: ["ax_region_delta", "ax_region_readback"]),
            .typedField(key: "note_count", type: .number),
            .typedField(key: "region_name", type: .string),
        ]
    )

    // MARK: - #373 Phase B3 — system safe-mutation oracles

    // SagaWire `storedOutcome(plan:outcome:)` → encodeStateA ONLY when
    // `outcome.state == .completed` (every other saga state maps to State B or C),
    // so `saga_state:"completed"` is exactly correlated with the State-A envelope
    // and is the load-bearing "the saga actually completed" invariant. `duplicate`
    // is NOT pinned: a replayed completion (`duplicateOutcome`) is still a genuine
    // State A with `duplicate:true`. `journal_scope`/`journal_survives_process_restart`
    // are the hardcoded session-journal honesty markers (SagaWire.sessionFields —
    // the same constants system.saga_preflight/saga_status pin). `steps` /
    // `state_history` carry the executed plan.
    static let systemSagaExecute = SafeMutationOracle.oracle(
        .systemSagaExecute,
        semantics: [
            .valueEquals(key: "journal_scope", expected: .string("session")),
            .valueEquals(key: "journal_survives_process_restart", expected: .bool(false)),
            .valueEquals(key: "saga_state", expected: .string("completed")),
            .typedField(key: "idempotency_key", type: .string),
            .typedField(key: "steps", type: .array),
            .typedField(key: "state_history", type: .array),
        ]
    )

    // SystemDispatcher `saga_cancel` reaches encodeStateA ONLY on the
    // `.cancelled(outcome, verified)` journal result WITH `verified == true` (an
    // unverified cancellation is State B sagaReconciliationRequired; pending is
    // State B sagaCancellationPending), so the State-A envelope proves the
    // compensation was CONFIRMED. `status:"cancelled"` is the terminal state,
    // `journal_scope`/`journal_survives_process_restart` are the session-journal
    // markers, and `outcome` carries the compensated result body.
    static let systemSagaCancel = SafeMutationOracle.oracle(
        .systemSagaCancel,
        semantics: [
            .valueEquals(key: "journal_scope", expected: .string("session")),
            .valueEquals(key: "journal_survives_process_restart", expected: .bool(false)),
            .valueEquals(key: "status", expected: .string("cancelled")),
            .typedField(key: "idempotency_key", type: .string),
            .typedField(key: "outcome", type: .object),
        ]
    )

    // SystemDispatcher `setup_arm_key` reaches encodeStateA on TWO outcomes —
    // `.alreadyConfigured` (verify-first fast path: the mapping already worked) and
    // `.configuredAndVerified` (GUI assignment confirmed by a live record-arm flip).
    // Both are gated on a FUNCTIONAL arm-flip verification (#413), which is what the
    // State-A envelope structurally proves. Their `evidence.extras` differ (the GUI
    // path emits the window/search/chord fields), so the only pinnable shared
    // content is the dispatcher-added constant `command:"Toggle Track Record Enable"`
    // (the exact Key Command the setup assigns) plus `chord` (the resolved chord
    // label) and `write_source` (always emitted by Evidence.extras). `write_source`
    // is shape-only (its value differs between the two State-A branches), so it is
    // typed, not value-pinned.
    static let systemSetupArmKey = SafeMutationOracle.oracle(
        .systemSetupArmKey,
        semantics: [
            .valueEquals(key: "command", expected: .string("Toggle Track Record Enable")),
            .typedField(key: "chord", type: .string),
            .typedField(key: "write_source", type: .string),
        ]
    )

    // SystemDispatcher `export_support_bundle` → encodeStateA({bundle_path, files})
    // ONLY after the bundle is written AND the created directory re-passes the
    // containment re-check (`createdBundleDirectoryIsContained`) — an escaped or
    // failed write is State C supportBundleExportFailed. The envelope carries the
    // value constraints (satisfying the anti-checkbox gate); the semantic content is
    // all environment-dependent (an absolute path and per-file sha256s, no
    // constant), so the honest pin is STRUCTURAL: a NON-EMPTY `files` manifest whose
    // entries carry `name`+`sha256`, plus a `bundle_path`. `.nonEmptyArray(files)`
    // is the "something was actually bundled" invariant — an empty manifest is not a
    // successful export.
    static let systemExportSupportBundle = SafeMutationOracle.oracle(
        .systemExportSupportBundle,
        semantics: [
            .nonEmptyArray(key: "files"),
            .typedField(key: "bundle_path", type: .string),
            .typedField(key: "files.0.name", type: .string),
            .typedField(key: "files.0.sha256", type: .string),
        ]
    )

    // MARK: - #373 Phase B3 — midi safe-mutation oracles

    // AccessibilityChannel+MIDIImport `defaultImportMIDIFile` → encodeStateA (chain
    // [.accessibility]). State A is reached ONLY when a new track appeared
    // (`afterCount > beforeCount` → `observed_delta` ≥ 1), no imported lane is a GM
    // Device / external-MIDI synth lane (else honest State B importedAsGMDevice),
    // and at least one imported MIDI region was read back (`importedRegions`
    // non-empty). So `.numericRange(imported_region_count, min: 1)` +
    // `.nonEmptyArray(imported_regions)` are the genuine "the imported content is
    // present" invariants, and `.numericRange(observed_delta, min: 1)` is the
    // "a track was created" invariant. `via:"ax_menu_import"` is the fixed
    // provenance and `file_open_dialog_seen:true` is hardcoded on the State-A path
    // (the import sheet was observed).
    static let midiImportFile = SafeMutationOracle.oracle(
        .midiImportFile,
        semantics: [
            .valueEquals(key: "via", expected: .string("ax_menu_import")),
            .valueEquals(key: "file_open_dialog_seen", expected: .bool(true)),
            .numericRange(key: "observed_delta", min: 1, max: 10_000),
            .numericRange(key: "imported_region_count", min: 1, max: 100_000),
            .nonEmptyArray(key: "imported_regions"),
            .typedField(key: "requested", type: .string),
            .typedField(key: "track_count_before", type: .number),
            .typedField(key: "track_count_after", type: .number),
        ]
    )

    // MIDIDispatcher `mmc_locate` is DUAL-path: a `bar` param routes
    // `transport.goto_position` and runs the SAME `finalizeGotoPositionResult` as
    // transport.goto_position/navigate.goto_bar, so its verified State A is that
    // identical shape — `requested == observed` playhead position (an independent
    // transport-state read, so a genuine request↔readback pin) plus
    // `verification_source:"transport_state"`. The `time` (SMPTE) sub-path routes
    // mmc.locate to [.coreMIDI] and is honest send-only State B, which the envelope
    // correctly rejects (it is not a verified write). This oracle pins the verified
    // bar-path State A; it is NOT a send-only op, so — unlike mmc_play/stop/record —
    // it is covered rather than excluded.
    static let midiMMCLocate = SafeMutationOracle.oracle(
        .midiMMCLocate,
        semantics: [
            .valueEquals(key: "verification_source", expected: .string("transport_state")),
            .fieldsEqual(keyA: "requested", keyB: "observed"),
            .typedField(key: "observed_time_position", type: .string),
        ]
    )

    // MARK: - #373 Phase B4 — plugin-insert / edit safe-mutation oracles

    // Each composes `SafeMutationOracle.verifiedEnvelope` (State A + verified +
    // success) with the op's own invariant, derived by READING its dispatcher/
    // channel handler. The envelope is always FIRST, so no oracle asserts what
    // changed before proving it was verified. (The export executors are the
    // exception — they emit a run RECORD, not an HC State-A envelope — see
    // projectExportRun.)
    //
    // mixer

    // AccessibilityChannel+Plugins `defaultInsertPlugin` → encodeStateA (chain
    // [.accessibility] for plugin.insert; MixerDispatcher.insert_plugin routes it
    // after a confirmation gate). State A is reached ONLY when the polled slot name
    // is non-nil AND `spec.matches(observed)` (the read-back plugin name normalizes
    // to the requested canonical name), so the "the plugin landed" proof is
    // STRUCTURAL — the envelope carries it. The pinnable content is the hardcoded
    // `verify_source:"ax_plugin_slot"` (the readback provenance), the requested
    // `plugin_name` domain (the allowlisted stock inserts — a claim of any other
    // plugin is caught), and the shape of the readback (`observed_plugin_name` is a
    // string on every State A, `track`/`slot` the addressed target). NOT
    // `.fieldsEqual(plugin_name, observed_plugin_name)`: `spec.matches` is a
    // case/whitespace-normalized compare, so a legitimate State A may carry a
    // differently-cased `observed_plugin_name` that an exact equality would
    // false-reject — the match itself is the structural State-A gate.
    static let mixerInsertPlugin = SafeMutationOracle.oracle(
        .mixerInsertPlugin,
        semantics: [
            .valueEquals(key: "verify_source", expected: .string("ax_plugin_slot")),
            .enumMember(key: "plugin_name", allowed: ["Gain", "Compressor", "Channel EQ"]),
            .typedField(key: "observed_plugin_name", type: .string),
            .typedField(key: "track", type: .number),
            .typedField(key: "slot", type: .number),
        ]
    )

    // plugins

    // AccessibilityChannel+VerifiedPlugins `defaultInsertVerified` →
    // encodeV2StateA (HC v2, chain [.accessibility]). The verified-insert path:
    // State A is reachable ONLY through the post-insert `get_inventory` readback
    // diff, and the handler gates it on `observedID == pluginID` (the requested
    // canonical id) AND `observedSlot == insert` (the requested slot) — every other
    // outcome (mismatch, landed-at-different-slot, readback-unavailable) fails closed
    // to State C/B. The envelope's `target_identity` carries the REQUESTED
    // {track_index, insert, plugin_id}, while `observed_plugin_id`/`observed_slot`
    // are the INDEPENDENT post-insert readback — so
    // `.fieldsEqual(target_identity.plugin_id, observed_plugin_id)` and
    // `.fieldsEqual(target_identity.insert, observed_slot)` are GENUINE
    // request↔readback pins (the RIGHT plugin landed in the RIGHT slot), not
    // same-source echoes. Plus `hc_schema:2`, the `operation` identity, and the
    // hardcoded `verify_source:"ax_plugin_inventory"` (the sole State-A provenance).
    // `write_source` is driver-supplied (trace-derived, defaulting to
    // ax_exact_slot_popup), so it is shape-typed, not value-pinned.
    static let pluginsInsertVerified = SafeMutationOracle.oracle(
        .pluginsInsertVerified,
        semantics: [
            .valueEquals(key: "hc_schema", expected: .number(2)),
            .valueEquals(key: "operation", expected: .string("logic_plugins.insert_verified")),
            .valueEquals(key: "verify_source", expected: .string("ax_plugin_inventory")),
            .fieldsEqual(keyA: "target_identity.plugin_id", keyB: "observed_plugin_id"),
            .fieldsEqual(keyA: "target_identity.insert", keyB: "observed_slot"),
            .typedField(key: "write_source", type: .string),
        ]
    )

    // project

    // ProjectExportExecutor.aggregate → `logic_pro_mcp_export_run.v1` RunResult
    // (ProjectDispatcher `export_run`). NOTE — this op is DELIBERATELY NOT built
    // through `SafeMutationOracle.oracle`: the executor emits a run RECORD keyed on
    // `status`, NOT an `HonestContract.encodeStateA` envelope (there is no
    // state/verified/success field). Pinning `state:"A"` would encode a shape the
    // handler never emits. The verified-execution proof is `status:"completed"`,
    // which the aggregator emits ONLY when `artifacts_failed == 0 &&
    // artifacts_uncertain == 0` — so `.valueEquals(artifacts_uncertain, 0)` +
    // `.valueEquals(artifacts_failed, 0)` are pinned ALONGSIDE the status as
    // independent guards (a handler that mislabels a partial run "completed" is
    // caught, mirroring the State-A triple-guard). `confirmed:true` (a completed run
    // is always a confirmed execution), the `run` mode (per-op discriminator — the
    // executor emits `mode: resume ? "resume" : "run"`), and the schema tag are the
    // hardcoded provenance. `artifacts_total >= 1` + a non-empty `projects` array are
    // the anti-vacuity gate (a "completed" export that produced nothing is not a
    // verified execution). Per-artifact HC state is not pinned at
    // `projects.0.artifacts.0` because the first project need not carry the first
    // artifact — the aggregate `artifacts_failed/uncertain == 0` captures the
    // per-artifact "every artifact reached State A" invariant.
    static let projectExportRun = OperationOracle(
        .projectExportRun,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_export_run.v1")),
            .valueEquals(key: "mode", expected: .string("run")),
            .valueEquals(key: "confirmed", expected: .bool(true)),
            .valueEquals(key: "status", expected: .string("completed")),
            .valueEquals(key: "artifacts_uncertain", expected: .number(0)),
            .valueEquals(key: "artifacts_failed", expected: .number(0)),
            .numericRange(key: "artifacts_total", min: 1, max: 100_000),
            .nonEmptyArray(key: "projects"),
            .typedField(key: "projects.0.artifacts", type: .array),
        ]
    )

    // ProjectExportExecutor.aggregate → same `logic_pro_mcp_export_run.v1` RunResult
    // as export_run, reached through ProjectDispatcher `export_resume` (idempotent
    // resume). The ONLY wire difference is `mode:"resume"` (the per-op discriminator),
    // so this oracle is export_run's twin with the mode flipped. A completed resume
    // may legitimately be all-SKIPPED (`artifacts_verified:0`, `artifacts_skipped:N`
    // — already-present-and-verified artifacts), so `artifacts_verified` is NOT
    // pinned to a minimum; the "nothing went wrong" gate (uncertain/failed == 0) plus
    // the non-vacuity gate (artifacts_total >= 1) are the shared verified-run pins.
    static let projectExportResume = OperationOracle(
        .projectExportResume,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_export_run.v1")),
            .valueEquals(key: "mode", expected: .string("resume")),
            .valueEquals(key: "confirmed", expected: .bool(true)),
            .valueEquals(key: "status", expected: .string("completed")),
            .valueEquals(key: "artifacts_uncertain", expected: .number(0)),
            .valueEquals(key: "artifacts_failed", expected: .number(0)),
            .numericRange(key: "artifacts_total", min: 1, max: 100_000),
            .nonEmptyArray(key: "projects"),
            .typedField(key: "projects.0.artifacts", type: .array),
        ]
    )

    // ProjectDispatcher `handleCleanupApply` → encodeStateA. cleanup_apply executes
    // ONE cleanup-plan rename step by delegating each target to the existing
    // TrackDispatcher.rename path, and reaches State A ONLY after EVERY target's
    // nested rename returned a verified State A (the loop fails closed to State C the
    // moment any target comes back isError/unverified) — so the "every rename
    // landed" proof is STRUCTURAL, carried by the envelope. The pinnable content is
    // the hardcoded provenance: `op:"project.cleanup_apply"` (NOTE the key is `op`,
    // not `operation`), the fixed `tool:"logic_tracks"` + `command:"rename"` (only
    // rename_* steps are executable), and `verify_source:"track.rename ax_readback"`
    // (the inherited readback provenance). `target_track_indices` + `applied` are
    // pinned NON-EMPTY (at least one track was actually renamed — an empty batch is
    // not a verified apply), and `step_id` is the applied plan step.
    static let projectCleanupApply = SafeMutationOracle.oracle(
        .projectCleanupApply,
        semantics: [
            .valueEquals(key: "op", expected: .string("project.cleanup_apply")),
            .valueEquals(key: "tool", expected: .string("logic_tracks")),
            .valueEquals(key: "command", expected: .string("rename")),
            .valueEquals(key: "verify_source", expected: .string("track.rename ax_readback")),
            .nonEmptyArray(key: "target_track_indices"),
            .nonEmptyArray(key: "applied"),
            .typedField(key: "step_id", type: .string),
        ]
    )

    // edit

    // AccessibilityChannel+Editing `defaultToggleStepInputKeyboard` → encodeStateA
    // (EditDispatcher routes edit.toggle_step_input [.accessibility, …]; the
    // midiKeyCommands/cgEvent fallbacks are send-only State B, so the AX path is the
    // ONLY State-A shape). State A is reached ONLY when the Step Input Keyboard
    // window open-state CHANGED after the menu press (`observedOpen != previousOpen`,
    // polled from the live AX window list), and the envelope carries both reads
    // (`previous_open`/`observed_open`) — so `observed_open == !previous_open`
    // (`.booleanFlipped`) is the GENUINE "the window toggled" invariant, relating two
    // independent AX reads, not a same-source echo. Plus the hardcoded
    // `operation:"edit.toggle_step_input"` and `via:"window-menu"` provenance.
    static let editToggleStepInput = SafeMutationOracle.oracle(
        .editToggleStepInput,
        semantics: [
            .valueEquals(key: "operation", expected: .string("edit.toggle_step_input")),
            .valueEquals(key: "via", expected: .string("window-menu")),
            .booleanFlipped(keyA: "observed_open", keyB: "previous_open"),
        ]
    )
}
