import ApplicationServices
import AppKit
import Foundation

/// Mixer surface: channel-strip state reads and volume/pan writes.
extension AccessibilityChannel {
    // MARK: - Mixer

    static func defaultGetMixerState(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        var channelStrips: [ChannelStripState] = []

        for (index, strip) in strips.enumerated() {
            let volume = AXLogicProElements.findVolumeFader(in: strip, runtime: runtime.ax)
                .flatMap { AXValueExtractors.extractLogicMixerFaderValue($0, runtime: runtime.ax) }
                ?? 0.0
            let pan = AXLogicProElements.findPanControl(in: strip, runtime: runtime.ax)
                .flatMap { AXValueExtractors.extractCenteredSliderValue($0, runtime: runtime.ax) }
                ?? 0.0

            var state = ChannelStripState(
                trackIndex: index,
                volume: volume,
                pan: pan
            )
            state.plugins = AXLogicProElements.pluginSlots(in: strip, runtime: runtime.ax)
            state.pluginsSource = "ax"
            channelStrips.append(state)
        }
        return encodeResult(channelStrips)
    }

    static func defaultGetChannelStrip(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        let strip = strips[index]
        let volume = AXLogicProElements.findVolumeFader(in: strip, runtime: runtime.ax)
            .flatMap { AXValueExtractors.extractLogicMixerFaderValue($0, runtime: runtime.ax) }
            ?? 0.0
        let pan = AXLogicProElements.findPanControl(in: strip, runtime: runtime.ax)
            .flatMap { AXValueExtractors.extractCenteredSliderValue($0, runtime: runtime.ax) }
            ?? 0.0

        var state = ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        state.plugins = AXLogicProElements.pluginSlots(in: strip, runtime: runtime.ax)
        state.pluginsSource = "ax"
        return encodeResult(state)
    }

    static func defaultSetMixerValue(
        params: [String: String],
        target: MixerTarget,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        // Accept both `value` (legacy) and `volume`/`pan` (dispatcher-side aliases)
        // — same contract-drift class of bug as transport.set_tempo's bpm/tempo.
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing 'index' parameter")
        }
        let label = target == .volume ? "volume" : "pan"
        guard let valueStr = params["value"] ?? params[label],
              let value = Double(valueStr) else {
            return .error("Missing 'value' or '\(label)' parameter")
        }
        let operation = target == .volume ? "mixer.set_volume" : "mixer.set_pan"
        let targetIdentity: [String: Any] = [
            "track_index": index,
            "control": label,
        ]

        // #107: target the per-track fader/pan slider in the track HEADER. It is
        // the same channel parameter as the mixer-strip control but identity-safe
        // (it belongs to exactly track `index`, so we can never write the wrong
        // strip the way positional indexing into a 2-strip Inspector mixer could)
        // and is available without the Mixer being visible. Logic ignores AXValue
        // writes on these sliders entirely (live-confirmed: `set 0.5` leaves a
        // 0.76 fader unmoved) — only AXIncrement/AXDecrement detents move them,
        // in deterministic ~10-raw-unit steps. We converge to the nearest
        // representable detent and read back every step.
        let slider: AXUIElement?
        switch target {
        case .volume: slider = AXLogicProElements.findTrackHeaderVolumeFader(at: index, runtime: runtime)
        case .pan:    slider = AXLogicProElements.findTrackHeaderPanControl(at: index, runtime: runtime)
        }
        guard let slider else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Cannot locate \(label) control for track \(index)",
                extras: [
                    "operation": operation,
                    "track": index,
                    "requested": value,
                    "target_identity": targetIdentity,
                    "recovery_hint": "Ensure track \(index) exists and the Tracks area is shown.",
                ]
            ))
        }
        guard let range = AXValueExtractors.extractSliderRange(slider, runtime: runtime.ax),
              range.max > range.min else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "\(label) slider for track \(index) exposes no AX range",
                extras: [
                    "operation": operation, "track": index, "requested": value,
                    "target_identity": targetIdentity, "verify_source": "ax_slider",
                ]
            ))
        }

        func readContract() -> Double? {
            switch target {
            case .volume: return AXValueExtractors.extractLogicMixerFaderValue(slider, runtime: runtime.ax)
            case .pan:    return AXValueExtractors.headerPanContract(slider, range: range, runtime: runtime.ax)
            }
        }
        let observedBefore = readContract()

        // Desired raw AX value for the requested contract value.
        let targetRaw: Double
        switch target {
        case .volume:
            targetRaw = AXValueExtractors.logicMixerFaderContractToRaw(value, range: range)
        case .pan:
            let center = (range.min + range.max) / 2.0
            let half = (range.max - range.min) / 2.0
            targetRaw = center + min(max(value, -1.0), 1.0) * half
        }

        // Closed-loop AXIncrement/AXDecrement nudge toward `targetRaw`. Stops on
        // reaching/crossing the target (landing on the nearer detent) or when no
        // detent moves the value (rail / unresponsive).
        var current = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        var steps = 0
        var stagnant = 0
        let maxSteps = 64
        while let cur = current, steps < maxSteps {
            if abs(cur - targetRaw) < 0.5 { break }
            let goingUp = cur < targetRaw
            _ = AXHelpers.performAction(slider, goingUp ? kAXIncrementAction : kAXDecrementAction, runtime: runtime.ax)
            steps += 1
            usleep(25_000)
            guard let next = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax) else { break }
            let crossed = (cur < targetRaw && next >= targetRaw) || (cur > targetRaw && next <= targetRaw)
            if crossed {
                // Land on whichever of cur/next is closer to the target.
                if abs(cur - targetRaw) < abs(next - targetRaw) {
                    _ = AXHelpers.performAction(slider, goingUp ? kAXDecrementAction : kAXIncrementAction, runtime: runtime.ax)
                    usleep(25_000)
                }
                break
            }
            if next == cur { stagnant += 1; if stagnant >= 2 { break } } else { stagnant = 0 }
            current = next
        }

        let observedRaw = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        let observedAfter = readContract()
        // One detent is ~10 raw units; "verified" means we converged to the
        // nearest AX-representable detent (within ~half a detent of target).
        let convergedToNearestDetent = observedRaw.map { abs($0 - targetRaw) <= 6.0 } ?? false

        var baseExtras: [String: Any] = [
            "operation": operation,
            "track": index,
            "control": label,
            "requested": value,
            "target_identity": targetIdentity,
            "observed_before": observedBefore ?? NSNull(),
            "observed_after": observedAfter ?? NSNull(),
            "observed": observedAfter ?? NSNull(),
            "observed_raw": observedRaw ?? NSNull(),
            "target_raw": targetRaw,
            "detent_raw_step": 10,
            "verify_source": "ax_slider",
            "write_method": "ax_increment_decrement",
            "nudge_steps": steps,
            "quantization_note": "Logic exposes this fader to AX in ~10-raw-unit detents; observed is the nearest representable level to requested.",
        ]
        if convergedToNearestDetent, let actual = observedAfter {
            baseExtras["observed"] = actual
            return .success(HonestContract.encodeStateA(extras: baseExtras))
        }
        return .success(HonestContract.encodeStateB(
            reason: observedAfter == nil ? .readbackUnavailable : .readbackMismatch,
            extras: baseExtras
        ))
    }

}
