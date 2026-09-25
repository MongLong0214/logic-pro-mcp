import ApplicationServices
import AppKit
import Foundation

/// Mixer surface: channel-strip state reads and volume/pan writes.
extension AccessibilityChannel {
    // MARK: - Mixer

    /// #982: a Mixer whose children did not read has strips nobody saw. Reporting it as an empty
    /// strip list, or an index as out of range, would state an absence that was never observed.
    static let mixerChildrenUnreadMessage =
        "The mixer's channel strips could not be read, so they are unknown, not absent. Retry the read."
    /// The same for one strip's insert chain, carried in `plugins_read_error`.
    static let stripChildrenUnreadMessage = "the strip's children did not read"

    static func defaultGetMixerState(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let lookup = AXLogicProElements.mixerAreaLookup(runtime: runtime)
        guard let mixer = lookup.mixer else {
            return .error(lookup.childrenUnread ? mixerChildrenUnreadMessage : "Cannot locate mixer — is it visible?")
        }
        guard let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax) else {
            return .error(mixerChildrenUnreadMessage)
        }
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
            readPluginChain(of: strip, into: &state, runtime: runtime)
            // #291: `output` has been on this model since it was written and nothing ever set it, so
            // `logic://mixer` published a field that was always null. It is read now; `nil` still
            // means "not identified", never "routed nowhere".
            state.output = AXLogicProElements.outputSlotDestination(in: strip, runtime: runtime.ax)
            state.input = AXLogicProElements.inputSlotSource(in: strip, runtime: runtime.ax)
            channelStrips.append(state)
        }
        return encodeResult(channelStrips)
    }

    /// `plugins_source: "ax"` says the chain was read and an empty list is an honest empty chain,
    /// so a strip whose children did not read gets no source and says why (#982).
    private static func readPluginChain(
        of strip: AXUIElement, into state: inout ChannelStripState, runtime: AXLogicProElements.Runtime
    ) {
        if let plugins = AXLogicProElements.pluginSlots(in: strip, runtime: runtime.ax) {
            state.plugins = plugins
            state.pluginsSource = "ax"
        } else {
            state.pluginsReadError = stripChildrenUnreadMessage
        }
    }

    static func defaultGetChannelStrip(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let lookup = AXLogicProElements.mixerAreaLookup(runtime: runtime)
        guard let mixer = lookup.mixer else {
            return .error(lookup.childrenUnread ? mixerChildrenUnreadMessage : "Cannot locate mixer — is it visible?")
        }
        guard let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax) else {
            return .error(mixerChildrenUnreadMessage)
        }
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
        readPluginChain(of: strip, into: &state, runtime: runtime)
        state.output = AXLogicProElements.outputSlotDestination(in: strip, runtime: runtime.ax)
        state.input = AXLogicProElements.inputSlotSource(in: strip, runtime: runtime.ax)
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
        // and is available without the Mixer being visible. AXIncrement/AXDecrement
        // move these sliders in deterministic ~10-raw-unit detents; we converge to
        // the nearest detent and read back every step. #973: an AXValue write does
        // not jump to the written value (`set 0.5` on a 0.76 fader looked unmoved),
        // but on Logic 12.3.1 it moved one raw unit toward it, which the fine phase uses.
        let slider: AXUIElement?
        switch target {
        case .volume: slider = AXLogicProElements.findTrackHeaderVolumeFader(at: index, runtime: runtime)
        case .pan:    slider = AXLogicProElements.findTrackHeaderPanControl(at: index, runtime: runtime)
        }
        guard let slider else {
            // #543: this refusal used to say only "cannot locate", which cannot be acted on by the
            // person who hit it and cannot be diagnosed by anyone who cannot reproduce it. Three steps
            // can fail here and they need different fixes: the track-header LIST was not found at all,
            // the header at this INDEX was not found (a count mismatch — the enumerator keeps only
            // `AXLayoutItem` children when any exist, so a header of another role shifts every index
            // after it), or the header was found and contains no `AXSlider` within the search depth.
            // Report which, with the counts that distinguish them. Structural facts only — roles,
            // counts, an index — no track name or other user content.
            // Read the rail ONCE, status-preserving. `allTrackHeaders` flattens three
            // different answers into one empty array, and this receipt's entire job is to
            // name which of them happened — reporting "list not found, header_count 0" for
            // a rail that WAS found but could not be traversed sends the reader hunting for
            // a missing Tracks area that is on screen. Zero is evidence only in `.read([])`.
            let headersRead: AXLogicProElements.TrackHeaderRead = AXLogicProElements
                .mainWindow(runtime: runtime)
                .map { AXLogicProElements.allTrackHeadersRead(in: $0, runtime: runtime) }
                ?? .unavailable

            // nil = the header at `index` WAS resolved; the slider search decides the step.
            var stepBeforeHeader: String?
            var headerCount: Int?
            var headerAtIndex: AXUIElement?
            switch headersRead {
            case .unavailable:
                stepBeforeHeader = "track_header_list_not_found"
            case .unreadable:
                // The rail exists; AX refused to enumerate it. Not an empty project.
                stepBeforeHeader = "track_header_list_unreadable"
            case .read(let headers):
                headerCount = headers.count
                // Index into the array we just read. Re-resolving via `findTrackHeader`
                // walks the tree a second time, so a track added or removed between the
                // two reads produced a receipt that contradicted itself — a header_count
                // of 3 next to "no_header_at_index" for index 1 — and named a wrong root
                // cause with full confidence.
                if headers.isEmpty {
                    stepBeforeHeader = "track_header_list_empty"
                } else if index >= 0 && index < headers.count {
                    headerAtIndex = headers[index]
                } else {
                    stepBeforeHeader = "no_header_at_index"
                }
            }
            let sliderCount = headerAtIndex.map {
                AXHelpers.findAllDescendants(of: $0, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax).count
            }
            let resolvedStep = stepBeforeHeader ?? ((sliderCount ?? 0) == 0
                ? "header_has_no_slider_within_depth_4"
                : "sliders_present_but_none_selected")
            var lookup: [String: Any] = [
                "failed_step": resolvedStep,
                "requested_index": index,
            ]
            // Only a successful read may state a count. Publishing 0 for an unreadable or
            // absent rail asserts "this project has no tracks", which we did not observe.
            if let headerCount { lookup["header_count"] = headerCount }
            if let sliderCount { lookup["sliders_in_header"] = sliderCount }
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Cannot locate \(label) control for track \(index) — \(resolvedStep)",
                extras: [
                    "operation": operation,
                    "track": index,
                    "requested": value,
                    "target_identity": targetIdentity,
                    "control_lookup": lookup,
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

        // #973: retried like `readSlider` below (#685). This read decides State A versus State B
        // too, and one dropped read here reported an exact landing as `readback_unavailable`.
        func readContract() -> Double? {
            var wait: UInt32 = 25_000
            for _ in 0..<4 {
                let value: Double?
                switch target {
                case .volume: value = AXValueExtractors.extractLogicMixerFaderValue(slider, runtime: runtime.ax)
                case .pan:    value = AXValueExtractors.headerPanContract(slider, range: range, runtime: runtime.ax)
                }
                if let value { return value }
                usleep(wait)
                wait *= 2
            }
            return nil
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
        // #685: both exits below used to be silent, and the measurement showed what that cost. On
        // the FIRST call of a fresh process — where the AX round trip is slow and the read
        // intermittently fails — the loop abandoned the write partway, four runs of four, moving
        // 58% to 87% of the requested travel and returning success with the fader left somewhere
        // nobody asked for.
        //
        // A nil read is the ABSENCE of an answer, not the answer "it did not move", so it is
        // retried with backoff before being treated as terminal. And a value unchanged 25ms after
        // an increment is a rail OR a read that has not caught up; those are indistinguishable at
        // that timescale, so stagnation is confirmed against a longer settle before it is believed.
        func readSlider() -> Double? {
            var wait: UInt32 = 25_000
            for _ in 0..<4 {
                if let value = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax) {
                    return value
                }
                usleep(wait)
                wait *= 2
            }
            return nil
        }

        let startRaw = readSlider()
        var current = startRaw
        var steps = 0
        var stagnant = 0
        let maxSteps = 64
        while let cur = current, steps < maxSteps {
            if abs(cur - targetRaw) < 0.5 { break }
            let goingUp = cur < targetRaw
            _ = AXHelpers.performAction(slider, goingUp ? kAXIncrementAction : kAXDecrementAction, runtime: runtime.ax)
            steps += 1
            usleep(25_000)
            guard var next = readSlider() else { break }
            if next == cur {
                usleep(150_000)
                next = readSlider() ?? next
            }
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

        // #973: an AXValue write moved the header slider one raw unit toward the written value on
        // Logic 12.3.1. The loop above leaves it within one detent (half, unless it reversed off a
        // rail), so walk the rest one write at a time; on a normalized 0...1 slider a unit is all of it.
        let rawUnitRange = range.max - range.min > 2
        var fineSteps = 0
        var lastFineWriteFrom: Double?
        var fineWriteReadMovingAway = false
        let detentRawStep = 10
        let maxFineSteps = detentRawStep
        while rawUnitRange, fineSteps < maxFineSteps, let cur = readSlider(), cur.rounded() != targetRaw.rounded() {
            guard AXHelpers.setAttribute(
                slider, kAXValueAttribute as String, NSNumber(value: targetRaw), runtime: runtime.ax
            ) else { break }
            fineSteps += 1
            lastFineWriteFrom = cur
            usleep(25_000)
            var next = readSlider()
            if next == cur {
                usleep(150_000)
                next = readSlider()
            }
            guard let next else { break }
            guard abs(next - targetRaw) < abs(cur - targetRaw) else {
                fineWriteReadMovingAway = abs(next - targetRaw) > abs(cur - targetRaw)
                break
            }
        }

        // Retried too, and for the same reason. This read is what decides State A versus State B:
        // a write that landed correctly and then failed its ONE verification read is reported as
        // unverified, which is honest about the read and wrong about the write. Measured after the
        // loop was fixed — a run that reached its target still came back State B here.
        let observedRaw = readSlider()
        let observedAfter = readContract()
        // Judged on the final read when there is one. When that read fails, the loop's own read is
        // the only witness left, and without it a write seen moving away was reported as a bare
        // `readback_unavailable`, as if nothing had been observed.
        var fineWriteMovedAway = false
        if let from = lastFineWriteFrom {
            if let raw = observedRaw {
                fineWriteMovedAway = abs(raw - targetRaw) > abs(from - targetRaw)
            } else {
                fineWriteMovedAway = fineWriteReadMovingAway
            }
        }
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
            "detent_raw_step": detentRawStep,
            "verify_source": "ax_slider",
            "write_method": "ax_increment_decrement",
            "nudge_steps": steps,
            "fine_steps": fineSteps,
            // On a normalized slider rounding would call 0.6 and 0.9 one position, so only equality counts.
            "reached_exact": observedRaw.map { rawUnitRange ? $0.rounded() == targetRaw.rounded() : $0 == targetRaw } ?? false,
            // #685: `nudge_steps` alone is not checkable — a partial move and a complete one look
            // the same in it. These two are what a caller, a log or an evidence document needs to
            // see that the loop stopped short, without re-reading the fader to find out.
            "detents_to_target": startRaw.map { ((abs(targetRaw - $0) / 10.0) * 100).rounded() / 100 } ?? NSNull(),
            "reached_target": convergedToNearestDetent,
            "quantization_note": "Logic moves this fader in ~10-raw-unit detents, and an AXValue write moved it one raw unit on Logic 12.3.1; reached_exact says whether observed_raw is the whole raw position nearest the request.",
        ]
        if fineWriteMovedAway {
            baseExtras["reason_detail"] = observedRaw == nil
                ? "An AXValue write was read moving the slider further from the target, and the fine phase stopped there without restoring it; the final read failed, so observed_raw is unknown."
                : "An AXValue write moved the slider further from the target, and the fine phase stopped there without restoring it; observed_raw is where it was left."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: baseExtras))
        }
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
