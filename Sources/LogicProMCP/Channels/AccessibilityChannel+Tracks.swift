import ApplicationServices
import AppKit
import Foundation

/// Track surface: enumerate/select tracks, mute/solo/arm/rename toggles, track creation via menu, and deletion.
extension AccessibilityChannel {
    // MARK: - Tracks

    static func defaultGetTracks(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        encodeResult(defaultGetTrackStates(runtime: runtime))
    }

    static func defaultGetTrackStates(runtime: AXLogicProElements.Runtime = .production) -> [TrackState] {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        return headers.enumerated().map { index, header in
            AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
        }
    }

    static func defaultGetSelectedTrack(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.extractSelectedState(header, runtime: runtime.ax) == true {
                let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    static func defaultSelectTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            // v3.1.0 (T3) — missing track is a hard failure; no retry will
            // help. Keep legacy error-string path for ChannelResult.error so
            // existing callers that look at .isSuccess still see a failure,
            // but encode the structured envelope.
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: ["requested": index]
            ))
        }
        // v3.0.3+ — activate Logic so the frontmost-dependent AX selection can
        // land, then go through the AX-native selection ladder (ADR-001: no
        // coordinate fallback — fail closed if every AX step is rejected).
        _ = ProcessUtils.Runtime.production.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) via the AX selection ladder",
                extras: ["requested": index]
            ))
        }

        // v3.1.0 (T3) — verifyTrackSelection already retries 6× at 100ms
        // intervals internally (see TrackSelectionVerification). We surface
        // the outcome as a 3-state Honest Contract response rather than the
        // legacy free-form text. Existing `verified:true/false` JSON path
        // stays valid because the new envelope still contains those keys.
        let verification = await verifyTrackSelection(index: index, runtime: runtime)
        let base: [String: Any] = ["requested": index, "selected": index]
        switch verification {
        case .verified:
            return .success(HonestContract.encodeStateA(extras: base.merging([
                "observed": index
            ]) { _, new in new }))
        case .selectionMetadataUnavailable:
            // Ralph-2 / W1 (guardian iter2) — retry budget exhausted: the
            // read-back metadata never surfaced across 6×100ms attempts.
            // Docs (README, CHANGELOG, API.md, PRD) consistently
            // promise `retry_exhausted` for this case; emitting
            // `readback_unavailable` here would make the enum an orphan.
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: base.merging(["observed": NSNull()]) { _, new in new }
            ))
        case .mismatch(let selectedIndex):
            // v3.1.0 (Ralph-2 / P2-2) — read-back succeeded but returned a
            // different index. That's the textbook `readback_mismatch` case
            // per docs/API.md (State B taxonomy).
            // `retry_exhausted` stays reserved for
            // `.selectionMetadataUnavailable` — read-back metadata never
            // appeared across the retry budget. Clients switching on
            // `reason` can now pick accept-and-diverge (mismatch) vs.
            // back-off-and-refetch (retry_exhausted) correctly.
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: base.merging([
                    "observed": selectedIndex as Any? ?? NSNull()
                ]) { _, new in new }
            ))
        case .trackDisappeared:
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) disappeared during selection verification",
                extras: base
            ))
        }
    }

    static func defaultSetTrackToggle(
        params: [String: String],
        button buttonName: String,
        runtime: AXLogicProElements.Runtime = .production,
        keyRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": { AXLogicProElements.findTrackMuteButton(trackIndex: $0, runtime: runtime) }
        case "Solo": { AXLogicProElements.findTrackSoloButton(trackIndex: $0, runtime: runtime) }
        case "Record": { AXLogicProElements.findTrackArmButton(trackIndex: $0, runtime: runtime) }
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        let desired: Bool = (params["enabled"] ?? "true") == "true"
        let baseExtras: [String: Any] = [
            "track": index,
            "button": buttonName,
            "requested": desired,
            "verification_source": "ax_value"
        ]

        // Success is judged ONLY by re-reading this checkbox AXValue (the
        // observed effect), NEVER by an AX action's return code: on real Logic
        // 12.x the track-header M/S/R actions return non-zero even when they
        // no-op (#106 sites-6/7), so trusting the return would fabricate a
        // State A on a control that never moved.
        func readValue() -> Bool? {
            guard let v = AXHelpers.getValue(button, runtime: runtime.ax) else { return nil }
            if let n = v as? NSNumber { return n.boolValue }
            if let b = v as? Bool { return b }
            if let i = v as? Int { return i != 0 }
            if let s = v as? String {
                switch s.lowercased() {
                case "1", "true": return true
                case "0", "false": return false
                default: return nil
                }
            }
            return nil
        }

        // Toggle-from-read: already at the desired state → verified no-op. No
        // rung runs, so no keyboard/coordinate event is ever fired.
        if let current = readValue(), current == desired {
            return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                "observed": desired,
                "action": "no-op"
            ]) { _, new in new }))
        }

        func pollMatched(deadlineMs: Int) -> Bool {
            let deadline = Date().addingTimeInterval(Double(deadlineMs) / 1000.0)
            repeat {
                if let after = readValue(), after == desired { return true }
                usleep(40_000)
            } while Date() < deadline
            return false
        }

        // #106 / ADR-001: coordinate-free per-op actuator ladder. Every rung
        // actuates WITHOUT any mouse/coordinate primitive (the former HID-click
        // last resort is deleted). Live-verified on Logic 12.3: SOLO flips on
        // AXPress; MUTE needs exclusive-select + key 'm'; ARM needs
        // exclusive-select + the configurable "Toggle Track Record Enable" key
        // chord. The read-back — not each rung's return value — decides State A.
        //
        // ARM honesty baseline: capture whether transport is ALREADY recording
        // (nil = UNREADABLE, kept distinct from readable-false) so a mis-assigned
        // arm key that instead triggers transport Record is caught by the guard
        // below, and an unreadable transport can never be coerced to "not
        // recording" under an arm State-A claim (#2).
        let recordingBaselineState: Bool? =
            (buttonName == "Record") ? transportRecordingState(runtime: runtime) : nil

        let outcome = runTrackToggleLadder(
            rungs: trackToggleLadder(
                button: button,
                buttonName: buttonName,
                index: index,
                desired: desired,
                readValue: readValue,
                runtime: runtime,
                keyRuntime: keyRuntime,
                processRuntime: processRuntime,
                environment: environment
            ),
            desired: desired,
            readValue: readValue,
            pollMatched: { pollMatched(deadlineMs: $0) }
        )

        switch outcome {
        case .refused(let refusal):
            // A refused rung posted NO key, so our action caused no transport
            // side effect — return the distinct fail-closed reason directly.
            return .error(HonestContract.encodeStateC(
                error: refusal.error,
                hint: refusal.hint,
                extras: baseExtras.merging(refusal.extras) { _, new in new }
            ))

        case .landed(let action):
            // ARM honesty guard — only when we would otherwise claim State A.
            if buttonName == "Record" {
                guard let post = transportRecordingState(runtime: runtime) else {
                    // Transport Record UNREADABLE post-actuate: we cannot prove the
                    // arm key did not instead start transport recording, so never
                    // claim a clean arm (#2). Fail closed, distinct from State A.
                    return .error(HonestContract.encodeStateC(
                        error: .transportStateUnknown,
                        hint: armTransportUnknownHint(index: index),
                        extras: baseExtras.merging(["transport_state": "unknown"]) { _, new in new }
                    ))
                }
                if post, recordingBaselineState != true {
                    // A mis-assigned key started transport Record instead of
                    // record-enable — fail closed even if the checkbox reads armed.
                    return .error(HonestContract.encodeStateC(
                        error: .axWriteFailed,
                        hint: armRecordingStartedHint(index: index),
                        extras: baseExtras.merging(["recording_started": true]) { _, new in new }
                    ))
                }
                if recordingBaselineState == true, !post {
                    return .error(HonestContract.encodeStateC(
                        error: .readbackMismatch,
                        hint: armRecordingStoppedHint(index: index),
                        extras: baseExtras.merging(["recording_stopped": true]) { _, new in new }
                    ))
                }
            }
            return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                "observed": desired,
                "action": action
            ]) { _, new in new }))

        case .exhausted:
            // Even a FAILED arm may have started transport Record via a
            // mis-assigned key — surface that distinctly when it is readable.
            if buttonName == "Record",
               let post = transportRecordingState(runtime: runtime),
               post, recordingBaselineState != true {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: armRecordingStartedHint(index: index),
                    extras: baseExtras.merging(["recording_started": true]) { _, new in new }
                ))
            }
            // Fail closed — NEVER a coordinate fallback.
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: trackToggleFailHint(buttonName: buttonName, index: index, desired: desired),
                extras: baseExtras
            ))
        }
    }

    // MARK: - Ladder runner (#3 double-toggle halt barrier)

    enum RungOutcome {
        case actuated
        case alreadyLanded
        case landed
        case refused(RungRefusal)
        case exhausted
    }

    /// A fail-closed refusal from a rung: a distinct Honest-Contract error, an
    /// operator-facing hint, and structured extras merged into the State C body.
    struct RungRefusal {
        let error: HonestContract.FailureError
        let hint: String
        let extras: [String: Any]
    }

    /// Terminal result of running the actuator ladder.
    enum LadderOutcome {
        case landed(action: String)
        case refused(RungRefusal)
        case exhausted
    }

    /// Run the actuator ladder with a HALT BARRIER between rungs (#3). Every rung
    /// is a TOGGLE, not a set: if an earlier rung actually flipped the control but
    /// its AXValue published only AFTER that rung's poll window closed, firing the
    /// next toggle rung would flip it straight BACK. So BEFORE actuating each rung
    /// (which includes re-reading after a prior rung's poll failed) we re-read the
    /// live value; if it ALREADY equals `desired`, we STOP and report State A
    /// attributed to the rung that actually moved it — never actuating again.
    /// `readValue` / `pollMatched` are injected so the barrier is unit-testable
    /// without live timing.
    static func runTrackToggleLadder(
        rungs: [TrackToggleRung],
        desired: Bool,
        readValue: () -> Bool?,
        pollMatched: (Int) -> Bool
    ) -> LadderOutcome {
        var lastActuated: String?
        for rung in rungs {
            // #3 halt barrier — re-read before EVERY actuation.
            if let current = readValue(), current == desired {
                return .landed(action: lastActuated ?? rung.name)
            }
            switch rung.actuate(pollMatched) {
            case .refused(let refusal):
                return .refused(refusal)
            case .alreadyLanded:
                return .landed(action: lastActuated ?? rung.name)
            case .landed:
                return .landed(action: rung.name)
            case .exhausted:
                return .exhausted
            case .actuated:
                lastActuated = rung.name
                if pollMatched(rung.pollMs) {
                    return .landed(action: rung.name)
                }
            }
        }
        return .exhausted
    }

    // MARK: - Coordinate-free track-toggle actuator (#106 / ADR-001)

    /// `kVK_ANSI_M` (46) — Logic's default "Mute selected tracks" key command.
    /// With the target track exclusively selected, pressing it flips that
    /// track-header Mute checkbox (live-verified on Logic 12.3); AXPress on the
    /// checkbox itself is a no-op.
    static let trackMuteKeyCode: CGKeyCode = 46

    /// `kVK_ANSI_S` (1) — Logic's default "Solo selected tracks" key command.
    /// AXPress on the track-header Solo checkbox is a live no-op on Logic 12.3.
    static let trackSoloKeyCode: CGKeyCode = 1

    static let logicFrontmostPollIntervalMicros: useconds_t = 100_000
    static let logicFrontmostStabilityPollCount = 4
    static let logicFrontmostStabilityTimeoutMicros: useconds_t = 2_000_000
    static let logicKeyWindowSettleMicros: useconds_t = 800_000
    static let syntheticKeyRetryAttempts = 3
    static let syntheticKeyRetryPollMs = 600
    static let syntheticKeyRetrySettleMicros: useconds_t = 200_000

    /// `kVK_ANSI_R` (15) — bare 'r' IS transport Record. NEVER post it for arm
    /// (it would start recording instead of toggling record-enable).
    static let transportRecordKeyCode: CGKeyCode = 15

    /// Default key CHORD for the record-ARM key command: Ctrl+Shift+E
    /// (`kVK_ANSI_E` (14) + control + shift). Live-confirmed target: Logic's
    /// "Toggle Track Record Enable" command, which toggles record-enable on the
    /// SELECTED track (distinct from transport Record). It ships UNASSIGNED, so
    /// the operator assigns it to this chord (or overrides via
    /// `LOGIC_PRO_MCP_ARM_KEYCODE` / `LOGIC_PRO_MCP_ARM_KEY_MODIFIERS`).
    static let defaultArmKeyCode: CGKeyCode = 14
    static let defaultArmModifiers: CGEventFlags = [.maskControl, .maskShift]

    /// Environment override keys for the record-arm chord.
    static let armKeyCodeEnvVar = "LOGIC_PRO_MCP_ARM_KEYCODE"
    static let armKeyModifiersEnvVar = "LOGIC_PRO_MCP_ARM_KEY_MODIFIERS"

    /// Outcome of resolving the record-arm key chord from the environment. A
    /// PRESENT-but-unparseable override is a CONFIGURATION ERROR — surfaced so the
    /// arm path fails closed with `arm_key_config_invalid` instead of silently
    /// falling back to the default chord or dropping unknown modifier tokens (#7).
    /// An ABSENT override still uses the built-in default.
    enum ArmChordResolution: Equatable {
        case resolved(code: CGKeyCode, flags: CGEventFlags)
        case invalidKeyCode(String)
        case invalidModifierToken(String)
    }

    /// Resolve the record-arm chord. `LOGIC_PRO_MCP_ARM_KEYCODE` (decimal virtual
    /// keycode) and `LOGIC_PRO_MCP_ARM_KEY_MODIFIERS` (comma list of
    /// control/shift/option/command) override the Ctrl+Shift+E default:
    ///   - ABSENT var → the built-in default (correct, silent).
    ///   - present + valid → parsed value.
    ///   - present keycode that does not parse → `.invalidKeyCode` (NO silent
    ///     fallback to 14).
    ///   - present modifiers with an unknown token → `.invalidModifierToken` (NO
    ///     silently dropped token).
    ///   - present-but-EMPTY modifiers → `.resolved` with no flags (a bare key),
    ///     which the arm path then refuses as unsafe.
    /// Injectable environment for deterministic tests.
    static func resolveArmChord(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ArmChordResolution {
        let code: CGKeyCode
        if let raw = environment[armKeyCodeEnvVar] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let parsed = UInt16(trimmed) else { return .invalidKeyCode(trimmed) }
            code = CGKeyCode(parsed)
        } else {
            code = defaultArmKeyCode
        }

        let flags: CGEventFlags
        if let raw = environment[armKeyModifiersEnvVar] {
            var parsed: CGEventFlags = []
            for token in raw.split(separator: ",") {
                let name = token.trimmingCharacters(in: .whitespaces).lowercased()
                if name.isEmpty { continue }
                switch name {
                case "control", "ctrl": parsed.insert(.maskControl)
                case "shift": parsed.insert(.maskShift)
                case "option", "opt", "alt": parsed.insert(.maskAlternate)
                case "command", "cmd": parsed.insert(.maskCommand)
                default: return .invalidModifierToken(name)
                }
            }
            flags = parsed
        } else {
            flags = defaultArmModifiers
        }
        return .resolved(code: code, flags: flags)
    }

    /// Single source of truth for arm-chord modifier validity: a bare key (no
    /// modifiers) is unsafe as an arm chord — bare 'r' IS transport Record and any
    /// bare key triggers a global command. Both the runtime arm actuator and the
    /// consent-based key-command auto-setup (#413) refuse such a chord.
    static func armChordModifiersAreUnsafe(_ flags: CGEventFlags) -> Bool {
        flags.isEmpty
    }

    /// Read whether Logic's transport is currently RECORDING (control-bar Record
    /// checkbox), returning nil when it is UNREADABLE. The arm honesty guard MUST
    /// keep nil DISTINCT from a readable `false`: coercing nil→false would let an
    /// unreadable transport masquerade as "not recording" under a State-A arm
    /// claim (#2).
    static func transportRecordingState(runtime: AXLogicProElements.Runtime) -> Bool? {
        AXLogicProElements.readControlBarCheckboxValue(
            named: "녹음", englishName: "Record", runtime: runtime
        )
    }

    /// Ground-truth verification for the arm-key auto-setup (#413): drive a real
    /// record-arm on track 0 through ONLY the given key chord and report whether
    /// record-enable actually flipped — then restore the arm state, the prior
    /// track selection, and the transport recording state, verifying each restore
    /// by read-back.
    ///
    /// The actuation is pinned to the CGEvent key chord alone — never AXPress and
    /// never the fallback toggle ladder. This is load-bearing: the ladder's other
    /// rungs (and a live control surface such as a virtual MCU port) can move
    /// record-enable WITHOUT the key command, which would let the verify pass on a
    /// host where the chord is unmapped and report a false "already configured".
    /// A flip observed here therefore proves the key command specifically is bound
    /// to the record-arm command. The typed result separates a cleanly UNMAPPED
    /// chord (no flip, nothing left mutated — safe to proceed to GUI assignment)
    /// from a PARTIAL restore (a flip or restore failed, host left dirty — must
    /// fail closed), a POST failure, and an unavailable environment, so a partially
    /// mutated host never receives further mutations.
    /// Functional arm-chord verification: flip record-enable with ONLY the chord,
    /// then restore it with the SAME chord, observing both transitions by AX
    /// read-back.
    ///
    /// #415 verify-causality: `.verified` requires TWO opposite chord-correlated
    /// transitions — the flip leg AND the restore leg — each gated by an
    /// arm-not-yet-at-target read immediately before a SUCCESSFUL post (see
    /// `postArmChordAndObserveFlip`). The restore leg IS the "second confirming
    /// flip" #415 asked to consider: a SINGLE external record-enable change
    /// landing inside one observation window (or a settle gap) can at most
    /// satisfy one leg, so with an unmapped chord it degrades to
    /// `.partialRestore` (fail-closed — never GUI assignment, never a false
    /// `.verified`); before any post it is never credited at all. The residual
    /// is DOUBLE external interference — two opposite flips, each landing inside
    /// its own ≤3×600ms window, mimicking both legs — which is observationally
    /// indistinguishable from the chord by AX read-back and is accepted as
    /// irreducible for this surface (a stricter single-attempt window would not
    /// remove it and costs live reliability against slow CGEvent delivery).
    static func armSetupVerify(
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        runtime: AXLogicProElements.Runtime = .production,
        keyRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production,
        // Once the command deadline fires this returns true; no verification chord
        // (flip or restore) is posted after it (#413).
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ArmKeyCommandSetup.VerifyResult {
        // No verification chord after the deadline — post ZERO keys.
        if isCancelled() { return .couldNotPost }
        guard let priorTransport = transportRecordingState(runtime: runtime) else { return .environmentUnavailable }
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let priorSelection = headers.map {
            AXValueExtractors.extractSelectedState($0, runtime: runtime.ax)
        }
        guard !headers.isEmpty, priorSelection.allSatisfy({ $0 != nil }),
              let trackHeaders = AXLogicProElements.getTrackHeaders(runtime: runtime) else {
            return .environmentUnavailable
        }
        let selectedHeaders = priorSelection.enumerated().compactMap { offset, selected in
            selected == true ? headers[offset] : nil
        }
        guard let armButton = AXLogicProElements.findTrackArmButton(trackIndex: 0, runtime: runtime),
              let curNum = AXHelpers.getValue(armButton, runtime: runtime.ax) as? NSNumber else {
            return .environmentUnavailable
        }
        let current = curNum.intValue != 0

        // Chord-ONLY flip to the opposite arm state.
        let flip = postArmChordAndObserveFlip(
            armButton: armButton, expected: !current,
            keyCode: keyCode, modifiers: modifiers,
            runtime: runtime, keyRuntime: keyRuntime, processRuntime: processRuntime,
            isCancelled: isCancelled
        )

        // If the chord flipped arm, restore it via the SAME chord and confirm.
        var armRestoreFailed = false
        if flip == .flipped {
            if isCancelled() {
                // The deadline fired after the flip — do NOT post a restore chord
                // (no new key after the deadline). Arm is left flipped; report it
                // honestly as a partial restore rather than claiming success.
                armRestoreFailed = true
            } else {
                armRestoreFailed = postArmChordAndObserveFlip(
                    armButton: armButton, expected: current,
                    keyCode: keyCode, modifiers: modifiers,
                    runtime: runtime, keyRuntime: keyRuntime, processRuntime: processRuntime,
                    isCancelled: isCancelled
                ) != .flipped
            }
        }

        // Restore the user's prior track selection (the drive exclusive-selected
        // track 0) and the transport recording state — AX-only, posts no key.
        let selectionRestored = restoreTrackSelection(
            headers: headers, priorSelection: priorSelection,
            selectedHeaders: selectedHeaders, trackHeaders: trackHeaders, runtime: runtime
        )
        let transportRestored = restoreTransportRecordingState(priorTransport, runtime: runtime)

        switch flip {
        case .flipped:
            if armRestoreFailed {
                return .partialRestore(detail: "record-enable was flipped to test the chord but could not be restored")
            }
            if !selectionRestored { return .partialRestore(detail: "the prior track selection could not be restored") }
            if !transportRestored { return .partialRestore(detail: "the transport recording state could not be restored") }
            return .verified
        case .postedNoFlip:
            // Nothing on the arm moved (unmapped), but the selection/transport the
            // drive touched must restore — otherwise the host is left dirty.
            if !selectionRestored { return .partialRestore(detail: "the prior track selection could not be restored") }
            if !transportRestored { return .partialRestore(detail: "the transport recording state could not be restored") }
            return .unmapped
        case .couldNotPost:
            if !selectionRestored { return .partialRestore(detail: "the prior track selection could not be restored") }
            if !transportRestored { return .partialRestore(detail: "the transport recording state could not be restored") }
            return .couldNotPost
        }
    }

    /// Restore the exact prior track selection captured before an exclusive-select
    /// side effect. AX-only (AXSelectedChildren + per-header AXSelected), posts no
    /// key. Returns whether the observed selection matches the captured prior.
    private static func restoreTrackSelection(
        headers: [AXUIElement],
        priorSelection: [Bool?],
        selectedHeaders: [AXUIElement],
        trackHeaders: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        _ = AXHelpers.setAttribute(
            trackHeaders, kAXSelectedChildrenAttribute, selectedHeaders as CFArray, runtime: runtime.ax
        )
        for (offset, header) in headers.enumerated() {
            _ = AXHelpers.setAttribute(
                header, kAXSelectedAttribute,
                priorSelection[offset] == true ? kCFBooleanTrue : kCFBooleanFalse,
                runtime: runtime.ax
            )
        }
        for attempt in 0..<4 {
            let observed = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
            if observed == priorSelection { return true }
            if attempt < 3 { usleep(80_000) }
        }
        return false
    }

    /// Exclusive-select track 0, confirm a safe keyboard focus, then post ONLY the
    /// CGEvent key chord (no AXPress, no other rung) and observe the arm read-back
    /// reach `expected`. The selection/focus gates are AX-only and observational,
    /// so they post no key and cannot themselves move arm — the only actuation is
    /// the chord, which is what makes an observed flip prove the key command.
    ///
    /// Success requires a CHORD-CAUSED transition: arm must read NOT-yet-`expected`
    /// immediately before a SUCCESSFUL post, then reach `expected` after it. An arm
    /// already at `expected` before any post is never credited — otherwise an
    /// external flip (a live control surface, another agent) could fabricate a pass
    /// for an unmapped chord. Only a post whose `postFlaggedKeyEvent` returned true
    /// enables the late-published double-toggle credit, so a FAILED post plus an
    /// external transition is never mistaken for chord causality. The result
    /// distinguishes a flip, a posted-but-no-flip (unmapped), and a could-not-post.
    private enum ChordFlipResult { case flipped, postedNoFlip, couldNotPost }

    private static func postArmChordAndObserveFlip(
        armButton: AXUIElement,
        expected: Bool,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        runtime: AXLogicProElements.Runtime,
        keyRuntime: AXMouseHelper.Runtime,
        processRuntime: ProcessUtils.Runtime,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ChordFlipResult {
        func armValue() -> Bool? {
            (AXHelpers.getValue(armButton, runtime: runtime.ax) as? NSNumber)?.boolValue
        }
        // No chord after the command deadline — post ZERO keys.
        if isCancelled() { return .couldNotPost }
        // The arm key command acts on the SELECTED track: exclusively select track
        // 0 and prove Logic is stably frontmost before any post.
        if confirmExclusiveSelectionRefusal(
            index: 0, runtime: runtime, processRuntime: processRuntime,
            sleepMicros: keyRuntime.sleepMicros
        ) != nil { return .couldNotPost }

        var anyPosted = false
        for attempt in 0..<syntheticKeyRetryAttempts {
            // Double-toggle guard: a SUCCESSFUL post THIS call already happened and
            // its flip published late — credit it without re-posting.
            if anyPosted, armValue() == expected { return .flipped }
            guard processRuntime.logicIsFrontmost(),
                  selectionIsExclusive(index: 0, runtime: runtime) else {
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            if syntheticKeyFocusRefusal(runtime: runtime) != nil {
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            // Causality: arm must be NOT-yet-`expected` right before the post, so an
            // arm already at `expected` (an external flip) is never chord-credited.
            guard armValue() != expected else {
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            // No new key after the deadline (checkpoint immediately before the post).
            if isCancelled() { return anyPosted ? .postedNoFlip : .couldNotPost }
            // Only a SUCCESSFUL post can be credited for a subsequent transition.
            let posted = keyRuntime.postFlaggedKeyEvent(keyCode, modifiers)
            anyPosted = anyPosted || posted
            guard posted else {
                if attempt < syntheticKeyRetryAttempts - 1 {
                    keyRuntime.sleepMicros(syntheticKeyRetrySettleMicros)
                    continue
                }
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            let deadline = Date().addingTimeInterval(Double(syntheticKeyRetryPollMs) / 1000.0)
            repeat {
                if armValue() == expected { return .flipped }   // transition observed after the post
                usleep(40_000)
            } while Date() < deadline
            if attempt < syntheticKeyRetryAttempts - 1 {
                keyRuntime.sleepMicros(syntheticKeyRetrySettleMicros)
            }
        }
        return anyPosted ? .postedNoFlip : .couldNotPost
    }

    /// Restore Logic's transport recording state to `prior`, verifying by
    /// read-back. Used by `armSetupVerify` so a mis-assigned arm chord that instead
    /// toggled transport Record can never be left recording.
    private static func restoreTransportRecordingState(
        _ prior: Bool,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let current = transportRecordingState(runtime: runtime) else { return false }
        if current != prior {
            guard let record = AXLogicProElements.findControlBarCheckbox(
                named: "녹음", englishName: "Record", runtime: runtime
            ) else { return false }
            _ = AXHelpers.performAction(record, kAXPressAction, runtime: runtime.ax)
        }
        for attempt in 0..<4 {
            if transportRecordingState(runtime: runtime) == prior { return true }
            if attempt < 3 { usleep(80_000) }
        }
        return false
    }

    typealias TrackToggleRung = (
        name: String,
        pollMs: Int,
        actuate: (_ pollMatched: (Int) -> Bool) -> RungOutcome
    )

    /// Per-op coordinate-free ladder. AXPress is always the natural primary
    /// (cheap; its return code is ignored and only read-back decides success).
    /// Mute/solo/arm add an exclusive-select-then-keyboard rung whose
    /// synthetic key is gated by: exclusive selection re-confirmed ATOMICALLY
    /// before the post (#4/#5), a safe keyboard focus (#6), and — for arm — a
    /// valid, non-bare key chord (#7). Any gate failing ⇒ the rung REFUSES (fails
    /// closed) without posting a key.
    static func trackToggleLadder(
        button: AXUIElement,
        buttonName: String,
        index: Int,
        desired: Bool,
        readValue: @escaping () -> Bool?,
        runtime: AXLogicProElements.Runtime,
        keyRuntime: AXMouseHelper.Runtime,
        processRuntime: ProcessUtils.Runtime,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [TrackToggleRung] {
        let pressRung: TrackToggleRung = ("press", 250, { _ in
            _ = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax)
            return .actuated
        })

        func retryingKeyOutcome(
            pollMatched: (Int) -> Bool,
            postKey: () -> Void
        ) -> RungOutcome {
            if let refusal = syntheticKeyFocusRefusal(runtime: runtime) {
                return .refused(refusal)
            }
            if let refusal = confirmExclusiveSelectionRefusal(
                index: index,
                runtime: runtime,
                processRuntime: processRuntime,
                sleepMicros: keyRuntime.sleepMicros
            ) { return .refused(refusal) }

            for attempt in 0..<syntheticKeyRetryAttempts {
                // Fresh live halt barrier before EVERY post: a late read-back
                // must never turn a successful toggle into a second toggle.
                if readValue() == desired {
                    return attempt == 0 ? .alreadyLanded : .landed
                }
                guard processRuntime.logicIsFrontmost() else {
                    return .refused(logicNotFrontmostRefusal(index: index))
                }
                guard selectionIsExclusive(index: index, runtime: runtime) else {
                    return .refused(selectionNotExclusiveRefusal(index: index))
                }
                if let refusal = syntheticKeyFocusRefusal(runtime: runtime) {
                    return .refused(refusal)
                }
                postKey()
                if pollMatched(syntheticKeyRetryPollMs) { return .landed }
                if attempt < syntheticKeyRetryAttempts - 1 {
                    keyRuntime.sleepMicros(syntheticKeyRetrySettleMicros)
                }
            }
            return .exhausted
        }

        switch buttonName {
        case "Solo":
            let keyRung: TrackToggleRung = ("keyboard-solo", syntheticKeyRetryPollMs, { poll in
                retryingKeyOutcome(pollMatched: poll) {
                    _ = keyRuntime.postKeyEvent(trackSoloKeyCode)
                }
            })
            return [pressRung, keyRung]
        case "Mute":
            let keyRung: TrackToggleRung = ("keyboard-mute", syntheticKeyRetryPollMs, { poll in
                retryingKeyOutcome(pollMatched: poll) {
                    _ = keyRuntime.postKeyEvent(trackMuteKeyCode)
                }
            })
            return [pressRung, keyRung]
        case "Record":
            let keyRung: TrackToggleRung = ("keyboard-arm", syntheticKeyRetryPollMs, { poll in
                // #7 configurable chord — a present-but-invalid override is a
                // config error, never a silent fallback to the default chord.
                let code: CGKeyCode
                let flags: CGEventFlags
                switch resolveArmChord(environment: environment) {
                case .resolved(let resolvedCode, let resolvedFlags):
                    code = resolvedCode
                    flags = resolvedFlags
                case .invalidKeyCode(let bad):
                    return .refused(armConfigInvalidRefusal(
                        reason: "\(armKeyCodeEnvVar)=\"\(bad)\" is not a valid decimal virtual keycode"
                    ))
                case .invalidModifierToken(let bad):
                    return .refused(armConfigInvalidRefusal(
                        reason: "\(armKeyModifiersEnvVar) contains an unknown modifier token \"\(bad)\""
                    ))
                }
                // A bare (no-modifier) arm key is unsafe: bare 'r' IS transport
                // Record, and any bare key is a global single-key command. Refuse
                // it — the default chord (Ctrl+Shift+E) carries modifiers, so only
                // an explicit empty-modifier override reaches here.
                if armChordModifiersAreUnsafe(flags) {
                    return .refused(armConfigInvalidRefusal(
                        reason: "a bare arm key with no modifiers is unsafe (bare 'r' starts transport "
                            + "recording; any bare key triggers a global command) — configure a modifier chord"
                    ))
                }
                return retryingKeyOutcome(pollMatched: poll) {
                    _ = keyRuntime.postFlaggedKeyEvent(code, flags)
                }
            })
            return [pressRung, keyRung]
        default:
            return [pressRung]
        }
    }

    /// Exclusive single-track selection guard. Keyboard mute/solo/arm act on the
    /// SELECTED track, so before posting any key we (1) activate Logic, (2) drive
    /// the AX `AXSelectedChildren` selection path, and (3) READ BACK that the target —
    /// and ONLY the target — is selected. Returns false (⇒ the key is NOT
    /// posted, so a wrong/multi selection can never toggle the wrong track)
    /// until exclusivity is confirmed within a bounded settle budget.
    static func confirmExclusiveSelection(
        index: Int,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        _ = AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime)
        for attempt in 0..<4 {
            if selectionIsExclusive(index: index, runtime: runtime) { return true }
            if attempt < 3 { usleep(80_000) }
        }
        return false
    }

    /// Read-only exclusivity predicate: the target — and ONLY the target — is
    /// selected. #5 fail-closed on uncertainty: EVERY non-target header must
    /// report a DEFINITIVE `AXSelected == false`; any nil/unreadable non-target
    /// selection state means we cannot PROVE it is unselected, so exclusivity is
    /// treated as UNPROVEN (returns false) rather than optimistically ignored. The
    /// target itself must read a definitive `true`.
    static func selectionIsExclusive(
        index: Int,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        guard index >= 0, index < headers.count else { return false }
        let states = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
        guard states[index] == true else { return false }
        return states.enumerated().allSatisfy { offset, state in
            offset == index || state == false
        }
    }

    /// Confirm exclusive selection with an ATOMIC re-check immediately before the
    /// key post (#4 TOCTOU): a second `confirmExclusiveSelection` right before the
    /// caller posts the key. Returns a distinct `selection_not_exclusive` refusal
    /// (#9) — NOT the generic write-fail hint — when exclusivity cannot be
    /// (re)proven, so the key is never posted onto a wrong/multi selection.
    /// nil ⇒ safe to post.
    static func confirmExclusiveSelectionRefusal(
        index: Int,
        runtime: AXLogicProElements.Runtime,
        processRuntime: ProcessUtils.Runtime,
        sleepMicros: (useconds_t) -> Void
    ) -> RungRefusal? {
        _ = ProcessUtils.activateLogicPro(runtime: processRuntime)

        var stablePolls = 0
        var elapsedMicros: useconds_t = 0
        var frontmostSettled = false
        while elapsedMicros < logicFrontmostStabilityTimeoutMicros {
            stablePolls = processRuntime.logicIsFrontmost() ? stablePolls + 1 : 0
            sleepMicros(logicFrontmostPollIntervalMicros)
            elapsedMicros += logicFrontmostPollIntervalMicros
            if stablePolls == logicFrontmostStabilityPollCount {
                guard processRuntime.logicIsFrontmost() else {
                    stablePolls = 0
                    continue
                }
                sleepMicros(logicKeyWindowSettleMicros)
                frontmostSettled = processRuntime.logicIsFrontmost()
                if frontmostSettled { break }
                stablePolls = 0
            }
        }
        guard frontmostSettled else { return logicNotFrontmostRefusal(index: index) }
        guard confirmExclusiveSelection(index: index, runtime: runtime) else {
            return selectionNotExclusiveRefusal(index: index)
        }
        // Re-confirm atomically right before the key — selection can change
        // between the first confirm and the post (multi-select, user shift-click,
        // Logic reselection). If it no longer holds, fail closed without posting.
        guard confirmExclusiveSelection(index: index, runtime: runtime) else {
            return selectionNotExclusiveRefusal(index: index)
        }
        guard processRuntime.logicIsFrontmost() else {
            return logicNotFrontmostRefusal(index: index)
        }
        return nil
    }

    /// #6 — refuse a synthetic global command key when Logic's keyboard focus is
    /// NOT known-safe: a modal/sheet is present, or the focused element is an
    /// editable text surface (rename field, Notes, search/combo box, or any
    /// element exposing a text insertion point). Posting 'm', 's', or the arm chord into
    /// such focus would type text or trigger the wrong command. Returns a refusal
    /// (⇒ do NOT post the key) on POSITIVE danger; nil ⇒ no unsafe focus detected
    /// (a nil focus is the common non-text case — the modal check covers sheets).
    /// Mute, Solo, and arm all use this gate before their synthetic key rung.
    static func syntheticKeyFocusRefusal(
        runtime: AXLogicProElements.Runtime
    ) -> RungRefusal? {
        if AXLogicProElements.dialogPresent(runtime: runtime) {
            return unsafeFocusRefusal(reason: "a modal dialog or sheet is present", focus: "modal")
        }
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return unsafeFocusRefusal(
                reason: "the Logic application root is unreadable — focus safety cannot be proven",
                focus: "app_root_unreadable"
            )
        }
        guard let focused: AXUIElement = AXHelpers.getAttribute(
            app, kAXFocusedUIElementAttribute, runtime: runtime.ax
        ) else {
            return unsafeFocusRefusal(
                reason: "Logic's focused element is unreadable — focus safety cannot be proven",
                focus: "focus_unreadable"
            )
        }
        guard let role = AXHelpers.getRole(focused, runtime: runtime.ax) else {
            return unsafeFocusRefusal(
                reason: "the focused element's role is unreadable — focus safety cannot be proven",
                focus: "role_unreadable"
            )
        }
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        if editableRoles.contains(role) {
            return unsafeFocusRefusal(
                reason: "an editable text field is focused (role \(role))", focus: role
            )
        }
        // A text insertion point marks an editable text surface even when the role
        // is unusual — a synthetic key would type into it.
        if let _: NSNumber = AXHelpers.getAttribute(
            focused, kAXInsertionPointLineNumberAttribute, runtime: runtime.ax
        ) {
            return unsafeFocusRefusal(
                reason: "a text-editing surface with an insertion point is focused",
                focus: role
            )
        }
        return nil
    }

    /// Fail-closed hint (read-back never flipped). Arm points the operator at
    /// the required "Toggle Track Record Enable" key-command assignment — the
    /// only coordinate-free arm path on Logic 12.x.
    static func trackToggleFailHint(buttonName: String, index: Int, desired: Bool) -> String {
        switch buttonName {
        case "Record":
            return "arm requires the Logic key command 'Toggle Track Record Enable' assigned to the "
                + "configured key (default Ctrl+Shift+E); assign it in Logic ▸ Key Commands, or set "
                + "LOGIC_PRO_MCP_ARM_KEYCODE/_MODIFIERS to your chosen key."
        case "Mute":
            return "track \(index) Mute=\(desired): read-back never matched after AXPress + "
                + "exclusive-select then key 'm' (coordinate-free actuators only)."
        case "Solo":
            return "track \(index) Solo=\(desired): read-back never matched after AXPress + "
                + "exclusive-select then key 's' (coordinate-free actuators only)."
        default:
            return "track \(index) \(buttonName)=\(desired): read-back never matched after AXPress "
                + "on the checkbox (coordinate-free actuators only)."
        }
    }

    /// Arm fail-closed hint for the mis-assignment case: the configured key
    /// started transport RECORDING instead of toggling record-enable.
    static func armRecordingStartedHint(index: Int) -> String {
        "arm aborted: the configured key started transport recording instead of arming track "
            + "\(index) — it is not assigned to 'Toggle Track Record Enable'. Stop the recording, then "
            + "assign that command (default Ctrl+Shift+E) in Logic ▸ Key Commands, or set "
            + "LOGIC_PRO_MCP_ARM_KEYCODE/_MODIFIERS to your chosen key."
    }

    static func armRecordingStoppedHint(index: Int) -> String {
        "arm aborted: the configured key stopped active transport recording instead of only arming track "
            + "\(index) — it is not assigned to 'Toggle Track Record Enable'. Restore recording as needed, then "
            + "assign that command (default Ctrl+Shift+E) in Logic ▸ Key Commands, or set "
            + "LOGIC_PRO_MCP_ARM_KEYCODE/_MODIFIERS to your chosen key."
    }

    /// #2 — arm fail-closed hint when the transport Record state is UNREADABLE at
    /// the post-actuate check, so a clean arm cannot be honestly claimed.
    static func armTransportUnknownHint(index: Int) -> String {
        "arm could not be confirmed for track \(index): the transport Record state was UNREADABLE, so "
            + "the server cannot prove the arm key did not instead start transport recording. Fail-closed "
            + "(no State A) — make Logic's control bar (with the Record button) visible, then retry."
    }

    /// #5/#9 — fail closed when exclusive selection cannot be proven.
    static func selectionNotExclusiveRefusal(index: Int) -> RungRefusal {
        RungRefusal(
            error: .selectionNotExclusive,
            hint: "track \(index) could not be exclusively selected before the key command "
                + "(another track is selected, or a header's selection state was unreadable). "
                + "Deselect other tracks and retry — the key was NOT posted.",
            extras: ["selection_error": "selection_not_exclusive"]
        )
    }

    static func logicNotFrontmostRefusal(index: Int) -> RungRefusal {
        RungRefusal(
            error: .logicNotFrontmost,
            hint: "track \(index) is exclusively selected, but Logic could not be confirmed frontmost. "
                + "Bring Logic frontmost and retry — the key was NOT posted.",
            extras: ["frontmost_error": "logic_not_frontmost"]
        )
    }

    /// #6 — refusal when Logic's keyboard focus is not known-safe for a synthetic
    /// global command key. The key was never posted.
    static func unsafeFocusRefusal(reason: String, focus: String) -> RungRefusal {
        RungRefusal(
            error: .unsafeFocusForSyntheticKey,
            hint: "refused to post the track key command: \(reason). Click the arrange/tracks area "
                + "(or dismiss the dialog) so keyboard focus is safe, then retry — the key was NOT posted.",
            extras: ["focus_guard": focus]
        )
    }

    /// #7 — refusal when the record-arm key override is present but invalid
    /// (unparseable keycode, unknown modifier token, or a bare no-modifier key).
    /// The key was never posted.
    static func armConfigInvalidRefusal(reason: String) -> RungRefusal {
        RungRefusal(
            error: .armKeyConfigInvalid,
            hint: "record-arm key configuration is invalid: \(reason). Fix "
                + "\(armKeyCodeEnvVar)/\(armKeyModifiersEnvVar) (or unset them to use the default "
                + "Ctrl+Shift+E) — the key was NOT posted.",
            extras: ["arm_key_config": "invalid"]
        )
    }

    static func defaultRenameTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "track.rename requires 'index' (Int) and 'name' (String)"
            ))
        }
        let truncatedName = String(name.prefix(255))
        let baseExtras: [String: Any] = ["track": index, "requested": truncatedName]

        func observedTrackName() -> String? {
            AXLogicProElements.trackName(at: index, runtime: runtime)
        }

        func verifiedResult(via: String) -> ChannelResult? {
            guard let observed = observedTrackName(), observed == truncatedName else { return nil }
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": observed,
                    "via": via
                ]) { _, new in new }
            ))
        }

        if let currentName = observedTrackName(), currentName == truncatedName {
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": currentName,
                    "via": "no-op"
                ]) { _, new in new }
            ))
        }

        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: baseExtras
            ))
        }

        if let field = AXLogicProElements.findTrackNameField(trackIndex: index, runtime: runtime) {
            AXHelpers.performAction(field, kAXPressAction, runtime: runtime.ax)
            AXHelpers.setAttribute(field, kAXValueAttribute, truncatedName as CFTypeRef, runtime: runtime.ax)
            AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax)
            usleep(50_000)
            if let verified = verifiedResult(via: "ax_set_value") {
                return verified
            }
        }

        _ = ProcessUtils.activateLogicPro(runtime: processRuntime)
        guard selectTrackForRename(index: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) before rename",
                extras: baseExtras
            ))
        }
        raiseTrackWindowForRename(index: index, runtime: runtime)

        let click = clickTrackMenu(
            ["Rename Track", "트랙 이름 변경", "이름 변경"],
            menuName: "트랙",
            englishMenuName: "Track",
            runtime: runtime
        )
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > Rename Track menu item not found / not pressable",
                extras: baseExtras
            ))
        }

        usleep(150_000)
        AXMouseHelper.typeText(truncatedName, runtime: mouseRuntime)
        usleep(50_000)
        AXMouseHelper.pressReturn(runtime: mouseRuntime)
        usleep(150_000)

        if let verified = verifiedResult(via: "track_menu") {
            return verified
        }

        AXMouseHelper.pressEscape(runtime: mouseRuntime)
        usleep(50_000)
        let observed = observedTrackName()
        return .success(HonestContract.encodeStateB(
            reason: observed == nil ? .readbackUnavailable : .readbackMismatch,
            extras: baseExtras.merging([
                "observed": observed as Any? ?? NSNull(),
                "via": "track_menu"
            ]) { _, new in new }
        ))
    }

    private static func raiseTrackWindowForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) {
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime),
              let window: AXUIElement = AXHelpers.getAttribute(header, kAXWindowAttribute, runtime: runtime.ax)
        else {
            return
        }
        _ = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        usleep(50_000)
    }

    private static func selectTrackForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) -> Bool {
        let initialHeaders = AXLogicProElements.allTrackHeaders(runtime: runtime)
        guard index >= 0 && index < initialHeaders.count else { return false }
        if AXValueExtractors.extractSelectedState(initialHeaders[index], runtime: runtime.ax) == true {
            return true
        }

        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return false
        }

        var sawSelectionMetadata = false
        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index < headers.count else { return false }

            let selectionStates = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
            if selectionStates.contains(where: { $0 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionStates[index] == true {
                return true
            }
            if attempt < 5 {
                usleep(100_000)
            }
        }
        return !sawSelectionMetadata
    }

    enum TrackSelectionVerification {
        case verified
        case selectionMetadataUnavailable
        case mismatch(selectedIndex: Int?)
        case trackDisappeared
    }

    static func verifyTrackSelection(
        index: Int,
        runtime: AXLogicProElements.Runtime
    ) async -> TrackSelectionVerification {
        var sawSelectionMetadata = false

        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index >= 0 && index < headers.count else {
                return .trackDisappeared
            }

            let selectionStates = headers.enumerated().map { offset, header in
                (offset, AXValueExtractors.extractSelectedState(header, runtime: runtime.ax))
            }
            if selectionStates.contains(where: { $0.1 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionStates[index].1 == true {
                return .verified
            }

            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard sawSelectionMetadata else {
            return .selectionMetadataUnavailable
        }

        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let selectedIndex = headers.enumerated().first {
            AXValueExtractors.extractSelectedState($0.element, runtime: runtime.ax) == true
        }?.offset
        return .mismatch(selectedIndex: selectedIndex)
    }

    // MARK: - Track Creation via Menu

    static func createTrackViaMenu(
        korean: String,
        english: String,
        expectedTrackType: TrackType,
        // Retained for channel-runtime compatibility. The create route no
        // longer invokes this unchecked keyboard fallback.
        confirmDialog: @escaping @Sendable () -> Void = { sendReturnKey() },
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard AXLogicProElements.mainWindow(runtime: runtime) != nil else {
            return .error("No document open for track creation")
        }

        // #348: clear a stray blocking modal BEFORE driving the Track menu — a
        // single-OK top-level alert (audio-interface warning on fresh-document /
        // first-track creation) otherwise wedges the create. Scoped with
        // `clearMandatoryNewTrack: false` so preflight NEVER clicks "Create": the
        // classifier-bound post-menu reconciliation below owns that, and doing
        // both would double-create. Acknowledges alerts + escapes stray
        // menus only; a no-op AX read when nothing is blocking.
        let reconcileOutcome = await reconcilePreflight(clearMandatoryNewTrack: false, runtime: runtime)

        // A mutation witness needs the same status-preserving rail read as the
        // delete path. The historic flattening enumerator turns a failed
        // pre-write read into `[]`, which makes tracks that were already there
        // look like the result of this menu click.
        let arrangeWindow = AXLogicProElements.arrangeWindowRead(runtime: runtime)
        let beforeTracks = observedTrackStates(in: arrangeWindow, runtime: runtime)

        // Try Korean locale first
        let result = clickTrackMenu(korean, menuName: "트랙", englishMenuName: "Track", runtime: runtime)
        let menuClickedTitle: String
        if result.isSuccess {
            menuClickedTitle = korean
        } else {
            // Fallback: English locale with English item title
            let fallback = clickTrackMenu(english, menuName: "Track", englishMenuName: "Track", runtime: runtime)
            guard fallback.isSuccess else { return fallback }
            menuClickedTitle = english
        }

        // Logic may publish a mandatory New Track dialog after the menu click.
        // Reconcile it through the classifier-bound AX Create element; Return
        // would actuate whichever default control happens to be focused and was
        // never read as this operation's target.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let dialogReconcileOutcome = await reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )
        let dialogConfirmationAttempted = dialogReconcileOutcome.actionAttempted
        let verificationReconcileOutcome = dialogReconcileOutcome.kind == .none
            && dialogReconcileOutcome.modalObservationIsComplete
            ? reconcileOutcome
            : dialogReconcileOutcome

        return await verifyTrackCreation(
            title: menuClickedTitle,
            expectedTrackType: expectedTrackType,
            beforeTracks: beforeTracks,
            arrangeWindow: arrangeWindow,
            dialogConfirmationAttempted: dialogConfirmationAttempted,
            reconcileOutcome: verificationReconcileOutcome,
            runtime: runtime
        )
    }

    /// Legacy keyboard fallback retained for injected runtime compatibility.
    /// Track creation deliberately does not call it: Return has no AX-bound
    /// target and can activate an unrelated default button.
    static func sendReturnKey() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let returnVK: CGKeyCode = 0x24
        if let down = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }

    private static func verifyTrackCreation(
        title: String,
        expectedTrackType: TrackType,
        beforeTracks: [TrackState]?,
        arrangeWindow: AXLogicProElements.ArrangeWindowRead,
        dialogConfirmationAttempted: Bool,
        reconcileOutcome: ModalReconcileOutcome,
        runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let beforeCount = beforeTracks?.count
        var lastObservedCount: Int?

        var extras: [String: Any] = [
            "menu_clicked": title,
            "track_count_before": beforeCount ?? NSNull(),
            "requested_delta": 1,
            "requested_track_type": expectedTrackType.rawValue,
            "dialog_confirmation_attempted": dialogConfirmationAttempted,
            "verification_source": "track_count_delta"
        ]
        // #348: note any pre-create reconciliation (alert acknowledged / stray
        // menu escaped). No-op when nothing was blocking, so the clean create
        // path stays byte-identical.
        mergeReconcileExtras(
            &extras,
            kind: reconcileOutcome.kind,
            action: attemptedReconcileActionLabel(reconcileOutcome),
            newTrackAutoConfirmed: reconcileOutcome.kind == .mandatoryNewTrack && reconcileOutcome.actionAttempted,
            witnessSummary: reconcileOutcome.witnessSummary,
            refusal: reconcileOutcome.refusal,
            actionFailure: reconcileOutcome.actionFailure,
            unreadableReason: reconcileOutcome.unreadableReason
        )

        for attempt in 0..<4 {
            let currentTracks = observedTrackStates(in: arrangeWindow, runtime: runtime)
            let currentCount = currentTracks?.count
            if let currentCount {
                lastObservedCount = currentCount
            }
            if let beforeTracks,
               let currentTracks,
               currentTracks.count > beforeTracks.count {
                var merged = extras.merging([
                    "track_count_after": currentTracks.count,
                    "observed_delta": currentTracks.count - beforeTracks.count
                ]) { _, new in new }
                if let observedTrack = observedCreatedTrack(before: beforeTracks, after: currentTracks) {
                    merged["observed_track_index"] = observedTrack.id
                    merged["observed_track_name"] = observedTrack.name
                    merged["observed_track_type"] = observedTrack.type.rawValue
                    merged["track_type_verification_source"] = "observed_header"
                }
                return .success(HonestContract.encodeStateA(extras: merged))
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        var merged = extras
        merged["track_count_after"] = lastObservedCount ?? NSNull()
        if let beforeCount, let lastObservedCount {
            merged["observed_delta"] = lastObservedCount - beforeCount
        } else {
            merged["observed_delta"] = NSNull()
        }
        // Without a successful pre-write rail read, a later count cannot tell
        // whether the tracks existed before the menu action. The write may have
        // happened, but State A is unavailable rather than a zero-count guess.
        guard beforeTracks != nil else {
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: merged
            ))
        }
        let dialogPresent = AXLogicProElements.dialogPresent(runtime: runtime)
        merged["dialog_present"] = dialogPresent
        if dialogPresent {
            merged["waiting_for_user"] = true
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: merged
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "track count did not increase after '\(title)' click within 4×1s budget",
            extras: merged
        ))
    }

    private static func observedTrackStates(
        in arrangeWindow: AXLogicProElements.ArrangeWindowRead,
        runtime: AXLogicProElements.Runtime = .production
    ) -> [TrackState]? {
        guard case .found(let window) = arrangeWindow,
              case .read(let headers) = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        else { return nil }
        return headers.enumerated().map { index, header in
            AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
        }
    }

    private static func observedCreatedTrack(
        before: [TrackState],
        after: [TrackState]
    ) -> TrackState? {
        if let selected = after.first(where: { $0.isSelected }) {
            return selected
        }
        guard after.count == before.count + 1 else {
            return after.last
        }
        var prefix = 0
        while prefix < before.count,
              trackCreationSignature(before[prefix]) == trackCreationSignature(after[prefix]) {
            prefix += 1
        }
        if prefix < after.count {
            return after[prefix]
        }
        return after.last
    }

    private static func trackCreationSignature(_ track: TrackState) -> String {
        [
            track.name,
            track.type.rawValue,
            String(track.isMuted),
            String(track.isSoloed),
            String(track.isArmed),
            track.color ?? ""
        ].joined(separator: "|")
    }

    /// Delete the currently-selected track via the `트랙 → 트랙 삭제` menu and
    /// verify the track count decremented by 1 within a 4×1s budget. Returns
    /// State A on confirmed delta, State B `retry_exhausted` if AX poll never
    /// catches the decrement, State C if the menu click itself fails.
    ///
    /// A deletion count is State A only after a *subsequent*, clean modal
    /// observation. Every non-`none` reconcile kind is still a blocker here,
    /// even if its action was accepted: a successful action is evidence of an
    /// attempted recovery, not proof that the modal set is now settled clean.
    static func deletionCountCanCertifyStateA(
        observedTrackCountDecreased: Bool,
        settledCleanModalObservation: Bool
    ) -> Bool {
        observedTrackCountDecreased && settledCleanModalObservation
    }

    /// A reconciliation is settled clean only after a read that finds no
    /// blocking modal at all. A witnessed action is deliberately insufficient:
    /// its close witness concerns the action's target, while State A needs a
    /// fresh observation of the complete blocker set.
    static func deletionModalObservationIsSettledClean(
        _ outcome: ModalReconcileOutcome,
        arrangeWindowWasRead: Bool
    ) -> Bool {
        // The modal read answers "no blocker", which is truthful even when there is no main window
        // to hold one — during `project.new` there genuinely is not one yet. A track deletion is
        // different: the count it just read comes FROM the arrange window, so a decrement observed
        // while that window cannot be resolved is a transient AX failure wearing the shape of a
        // successful delete. Require the window here, where the requirement actually belongs,
        // rather than making every caller of the modal read pretend absence is unreadable.
        outcome.kind == .none
            && outcome.modalObservationIsComplete
            && arrangeWindowWasRead
    }

    /// Two complete clean reads make the delete State-A gate temporal rather
    /// than a single racy snapshot. The delete poll cadence is one second, so
    /// a decrement pays one additional ~1s observation interval before State A
    /// can be certified.
    static func deletionCleanObservationStreakIsSettled(
        _ consecutiveCleanObservationCount: Int
    ) -> Bool {
        consecutiveCleanObservationCount >= 2
    }

    static func defaultDeleteTrack(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        // Resolve the arrange window once for the entire destructive envelope.
        // The before and after counts must describe this same AX element; a
        // best-effort `mainWindow()` read can otherwise flatten an unreadable
        // rail to zero or silently switch windows between the two observations.
        let arrangeWindow = AXLogicProElements.arrangeWindowRead(runtime: runtime)
        let beforeTrackRead: AXLogicProElements.TrackHeaderRead
        switch arrangeWindow {
        case .found(let window):
            beforeTrackRead = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        case .absent:
            beforeTrackRead = .unavailable
        case .unreadable:
            beforeTrackRead = .unreadable
        }
        let beforeCount: Int?
        switch beforeTrackRead {
        case .read(let headers):
            beforeCount = headers.count
        case .unavailable, .unreadable:
            beforeCount = nil
        }
        let click = clickTrackMenu(
            ["Delete Track", "트랙 삭제"],
            menuName: "트랙",
            englishMenuName: "Track",
            runtime: runtime
        )
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > Delete Track / 트랙 삭제 menu item not found / not pressable",
                extras: ["track_count_before": beforeCount ?? NSNull()]
            ))
        }

        let menuClicked = (
            (try? JSONSerialization.jsonObject(with: Data(click.message.utf8))) as? [String: String]
        )?["menu_clicked"] ?? "Delete Track / 트랙 삭제"

        var extras: [String: Any] = [
            "menu_clicked": menuClicked,
            "track_count_before": beforeCount ?? NSNull(),
            "requested_delta": -1
        ]

        // #346: a channel-strip delete raises a "delete channel strips…" confirm
        // sheet, and a delete that empties the project raises the mandatory New
        // Track sheet (Cancel disabled, Escape inert) — both wedge Logic until
        // reconciled. Each sheet KIND receives at most one direct action while
        // it remains visible; a sequential delete-confirm → mandatory-New-Track
        // transition can therefore reconcile both without double-pressing either.
        // Reconciliation is ADDITIVE:
        // State A below still requires a real decrement, so auto-Creating a
        // replacement track on delete-to-zero correctly stays an honest State B
        // rather than a fabricated success.
        var reconcileKind = ModalReconciliation.BlockingModalKind.none
        var reconcileAction = "none"
        var reconcileActionKind = ModalReconciliation.BlockingModalKind.none
        // #453: an acknowledgement the executor declined must reach the envelope.
        // Kept beside kind/action so a refusal on any attempt survives to the
        // result, rather than being overwritten by a later clean pass.
        var reconcileRefusal: AlertAcknowledgeRefusal?
        var reconcileActionFailure: AXHelpers.AXActionError?
        var reconcileWitnessSummary: ModalReconcileWitnessSummary?
        var reconcileUnreadableReason: ModalReadFailure?
        var actionAttemptedModalKinds: Set<String> = []
        var mandatoryNewTrackReconciliationPerformed = false
        var consecutiveCleanModalObservations = 0

        // `nil` means no post-delete rail read succeeded. Do not initialize this
        // from `beforeCount`: serialising that pre-delete number as "after" makes
        // four unreadable polls externally indistinguishable from four observed
        // no-delta polls.
        var lastObservedCount: Int?
        for attempt in 0..<4 {
            try? await Task.sleep(nanoseconds: 250_000_000)

            // Carry the operation's one resolved arrange candidate into every
            // post-delete header and modal read. A failed header traversal is
            // deliberately not `0`: only `.read([])` is an observed empty rail,
            // so a transient AX failure cannot resemble a successful delete.
            let currentTrackRead: AXLogicProElements.TrackHeaderRead
            switch arrangeWindow {
            case .found(let window):
                currentTrackRead = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
            case .absent:
                currentTrackRead = .unavailable
            case .unreadable:
                currentTrackRead = .unreadable
            }
            let currentCount: Int?
            switch currentTrackRead {
            case .read(let headers):
                currentCount = headers.count
                lastObservedCount = headers.count
            case .unavailable, .unreadable:
                currentCount = nil
            }
            // Observe first, then action only once for that visible sheet kind.
            // This bounds a Create press without globally wedging a later,
            // different blocker in the same delete operation.
            let observed = observeModalAfterMutation(
                isDeleteContext: true,
                arrangeWindow: arrangeWindow,
                runtime: runtime
            )
            let outcome: ModalReconcileOutcome
            if observed.kind != .none,
               !actionAttemptedModalKinds.contains(reconcileKindLabel(observed.kind)) {
                outcome = await reconcileAfterMutation(isDeleteContext: true, runtime: runtime)
                if outcome.actionAttempted {
                    actionAttemptedModalKinds.insert(reconcileKindLabel(outcome.kind))
                }
            } else {
                outcome = observed
            }
            if outcome.kind != .none {
                reconcileKind = outcome.kind
                // Never claim a decision label as an action when no direct
                // press/key event was issued. If this is a later observation of
                // the same sheet kind, retain its earlier actual action label;
                // if it is a new unacted kind, clear the old kind's label.
                if outcome.actionAttempted {
                    reconcileAction = reconcileActionLabel(outcome.decision)
                    reconcileActionKind = outcome.kind
                } else if reconcileActionKind != outcome.kind {
                    reconcileAction = "none"
                    reconcileActionKind = .none
                }
                if let refusal = outcome.refusal { reconcileRefusal = refusal }
                if let actionFailure = outcome.actionFailure { reconcileActionFailure = actionFailure }
                if let unreadableReason = outcome.unreadableReason {
                    reconcileUnreadableReason = unreadableReason
                }
                // A current unacted *new* blocker must not inherit a witness
                // from a prior sheet. A repeated observation of the same kind
                // retains its own prior direct-action witness.
                if outcome.actionAttempted || reconcileActionKind != outcome.kind {
                    reconcileWitnessSummary = outcome.witnessSummary
                }
                if outcome.kind == .mandatoryNewTrack, outcome.actionAttempted {
                    mandatoryNewTrackReconciliationPerformed = true
                }
            } else if outcome.modalObservationIsComplete {
                // A complete clean pass proves the prior visible kinds closed,
                // so a later instance is eligible for one fresh direct action.
                actionAttemptedModalKinds.removeAll()
                reconcileUnreadableReason = nil
            } else if let unreadableReason = outcome.unreadableReason {
                // An incomplete no-modal answer is neither a blocker nor a
                // clean pass. Preserve its diagnostic and leave the action
                // latch intact until a later complete observation settles it.
                reconcileUnreadableReason = unreadableReason
            }
            let observedTrackCountDecreased = beforeCount.flatMap { beforeCount in
                currentCount.map { $0 < beforeCount }
            } ?? false
            if observedTrackCountDecreased,
               deletionModalObservationIsSettledClean(
                   // The direct recovery path may perform a fresh read in
                   // order to bind an action to its classifier. That later
                   // read is not this poll's sheet observation, so it cannot
                   // turn a sheet we just saw on `arrangeWindow` into clean.
                   // Only `observed` shares the count's resolved window.
                   observed,
                   arrangeWindowWasRead: currentCount != nil
               ) {
                consecutiveCleanModalObservations += 1
            } else {
                consecutiveCleanModalObservations = 0
            }
            if let beforeCount,
               let currentCount,
               deletionCountCanCertifyStateA(
                observedTrackCountDecreased: observedTrackCountDecreased,
                settledCleanModalObservation: deletionCleanObservationStreakIsSettled(
                    consecutiveCleanModalObservations
                )
            ) {
                extras["track_count_after"] = currentCount
                extras["observed_delta"] = currentCount - beforeCount
                mergeReconcileExtras(
                    &extras,
                    kind: reconcileKind,
                    action: reconcileAction,
                    newTrackAutoConfirmed: mandatoryNewTrackReconciliationPerformed,
                    witnessSummary: reconcileWitnessSummary,
                    refusal: reconcileRefusal,
                    actionFailure: reconcileActionFailure,
                    unreadableReason: reconcileUnreadableReason
                )
                return .success(HonestContract.encodeStateA(extras: extras))
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        extras["track_count_after"] = lastObservedCount ?? NSNull()
        if let beforeCount, let lastObservedCount {
            extras["observed_delta"] = lastObservedCount - beforeCount
        } else {
            extras["observed_delta"] = NSNull()
        }
        if reconcileKind == .mandatoryNewTrack {
            extras["mandatory_track_reconciliation_performed"] = mandatoryNewTrackReconciliationPerformed
        }
        mergeReconcileExtras(
            &extras,
            kind: reconcileKind,
            action: reconcileAction,
            newTrackAutoConfirmed: mandatoryNewTrackReconciliationPerformed,
            witnessSummary: reconcileWitnessSummary,
            refusal: reconcileRefusal,
            actionFailure: reconcileActionFailure,
            unreadableReason: reconcileUnreadableReason
        )
        return .success(HonestContract.encodeStateB(
            reason: .retryExhausted,
            extras: extras
        ))
    }

    private static func clickTrackMenu(
        _ menuItemTitle: String,
        menuName: String = "트랙",
        englishMenuName: String = "Track",
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        clickTrackMenu([menuItemTitle], menuName: menuName, englishMenuName: englishMenuName, runtime: runtime)
    }

    private static func clickTrackMenu(
        _ menuItemTitles: [String],
        menuName: String = "트랙",
        englishMenuName: String = "Track",
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        for menuTitle in [menuName, englishMenuName] {
            for itemTitle in menuItemTitles {
                guard let item = AXLogicProElements.menuItem(path: [menuTitle, itemTitle], runtime: runtime) else {
                    continue
                }
                guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
                    return .error("Failed to click menu item: \(itemTitle)")
                }
                return .success("{\"menu_clicked\":\"\(itemTitle)\"}")
            }
        }
        let joinedTitles = menuItemTitles.joined(separator: " | ")
        return .error("Cannot find menu item: \(menuName) > \(joinedTitles)")
    }

}
