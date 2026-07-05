import ApplicationServices
import Foundation

/// Extract typed values from AX elements.
/// These handle the various ways Logic Pro represents values in its AX tree.
enum AXValueExtractors {
    /// Extract a numeric value from a slider (volume fader, pan knob, etc.)
    /// Returns the AXValue as a Double, or nil if unavailable.
    static func extractSliderValue(_ element: AXUIElement, runtime: AXHelpers.Runtime = .production) -> Double? {
        guard let value = AXHelpers.getValue(element, runtime: runtime) else { return nil }
        // AXSlider values can come as NSNumber or CFNumber
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        // Try string-based value and parse
        if let str = value as? String, let parsed = Double(str) {
            return parsed
        }
        return nil
    }

    /// Read an AX slider's `AXValueDescription` — the human-readable, unit-bearing
    /// rendering of its value (e.g. Logic plugin-window Threshold reads "60 %").
    /// Returns nil when the attribute is absent. Verified-plugin readback (R6
    /// step 12) surfaces this verbatim as `observed_display`.
    static func extractValueDescription(_ element: AXUIElement, runtime: AXHelpers.Runtime = .production) -> String? {
        AXHelpers.getAttribute(element, kAXValueDescriptionAttribute, runtime: runtime)
    }

    /// Set an AX slider's `AXValue` to `value`. Logic plugin-window parameter
    /// sliders accept a numeric `AXValue` write (T0 spike: `set AXValue 60`
    /// lands and reads back). Returns true on a successful AX write. The value is
    /// bridged to `NSNumber` so it crosses the `CFTypeRef` boundary the same way
    /// the live AX API expects.
    @discardableResult
    static func setSliderValue(
        _ element: AXUIElement,
        _ value: Double,
        runtime: AXHelpers.Runtime = .production
    ) -> Bool {
        AXHelpers.setAttribute(element, kAXValueAttribute, NSNumber(value: value), runtime: runtime)
    }

    /// Extract a text value from a static text or text field element.
    /// Used for tempo display, position readout, track names, etc.
    static func extractTextValue(_ element: AXUIElement, runtime: AXHelpers.Runtime = .production) -> String? {
        // Try kAXValueAttribute first (text fields, static text)
        if let value = AXHelpers.getValue(element, runtime: runtime) as? String {
            return value
        }
        // Fallback to kAXTitleAttribute
        return AXHelpers.getTitle(element, runtime: runtime)
    }

    /// Extract a boolean state from a button or checkbox element.
    /// For toggle buttons (mute, solo, arm, cycle, metronome), the value
    /// indicates pressed/active state.
    static func extractButtonState(_ element: AXUIElement, runtime: AXHelpers.Runtime = .production) -> Bool? {
        guard let value = AXHelpers.getValue(element, runtime: runtime) else { return nil }
        // Toggle buttons typically report 0/1 as NSNumber
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let bool = value as? Bool {
            return bool
        }
        // Some buttons use string "1"/"0"
        if let str = value as? String {
            return str == "1" || str.lowercased() == "true"
        }
        return nil
    }

    /// Extract the selected state of an element.
    static func extractSelectedState(_ element: AXUIElement, runtime: AXHelpers.Runtime = .production) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXSelectedAttribute, runtime: runtime) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Extract slider range (min/max) for interpreting fader values.
    struct SliderRange {
        let min: Double
        let max: Double
    }

    static func extractSliderRange(_ element: AXUIElement, runtime: AXHelpers.Runtime = .production) -> SliderRange? {
        guard let minVal: AnyObject = AXHelpers.getAttribute(element, kAXMinValueAttribute, runtime: runtime),
              let maxVal: AnyObject = AXHelpers.getAttribute(element, kAXMaxValueAttribute, runtime: runtime),
              let min = (minVal as? NSNumber)?.doubleValue,
              let max = (maxVal as? NSNumber)?.doubleValue else {
            return nil
        }
        return SliderRange(min: min, max: max)
    }

    /// Normalize a unipolar Logic AX slider to 0.0...1.0 using its live
    /// AXMin/AXMax range. Logic Pro 12.2 exposes mixer faders as raw values
    /// like 70 in a 0...233 range, while the public MCP mixer contract uses
    /// normalized 0...1 values.
    static func extractNormalizedSliderValue(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> Double? {
        guard let value = extractSliderValue(element, runtime: runtime),
              let range = extractSliderRange(element, runtime: runtime),
              range.max > range.min else {
            // Fail-closed (audit #17): without a usable range we cannot normalize,
            // so BOUND the raw reading to the widest valid slider contract this
            // primitive serves — [-1, 1] — instead of leaking an unbounded raw
            // value. This is the fallback for the bipolar `extractCenteredSliderValue`
            // (a rangeless pan slider reports its value already in the -1...1 pan
            // contract), so the bound MUST admit negatives; a [0, 1] clamp here
            // silently zeroed real left-pan readings.
            return extractSliderValue(element, runtime: runtime).map { min(max($0, -1.0), 1.0) }
        }
        let normalized = (value - range.min) / (range.max - range.min)
        return min(max(normalized, 0.0), 1.0)
    }

    /// Convert Logic's AX fader-position value into the public mixer volume
    /// contract used by `mixer.set_volume`. Logic's AX slider range is not a
    /// linear mirror of the MCU 14-bit fader position; live Logic 12.2 reads
    /// show a stable fader taper (e.g. MCP 0.4 reads as AX 70/233). Interpolate
    /// the observed taper so AX readback and `logic://mixer` speak the same
    /// units as mixer writes.
    static func extractLogicMixerFaderValue(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> Double? {
        guard let value = extractSliderValue(element, runtime: runtime) else {
            return nil
        }
        guard let range = extractSliderRange(element, runtime: runtime),
              range.max > range.min else {
            // Fail-closed to the 0.0...1.0 mixer-volume contract (audit #17): an
            // already-normalized slider passes through unchanged (0.8 -> 0.8),
            // but a rangeless raw reading is clamped instead of leaking out of
            // contract.
            return min(max(value, 0.0), 1.0)
        }
        let position = min(max((value - range.min) / (range.max - range.min), 0.0), 1.0)
        guard isLogicMixerRawFaderRange(range) else {
            return position
        }
        return logicMixerFaderPositionToContract(position)
    }

    private static func isLogicMixerRawFaderRange(_ range: SliderRange) -> Bool {
        range.min == 0.0 && range.max > 2.0
    }

    /// Convert the public `mixer.set_volume` contract value back into the live
    /// Logic 12 raw fader position so AX writes land at the intended level.
    static func logicMixerFaderContractToPosition(_ contract: Double) -> Double {
        let clamped = min(max(contract, 0.0), 1.0)
        let points: [(contract: Double, position: Double)] = [
            (0.0, 0.0),
            (0.2, 0.1072961373390558),
            (0.4, 70.0 / 233.0),
            (0.5, 0.4206008583690987),
            (0.6, 0.48497854077253216),
            (0.8, 0.8111587982832618),
            (1.0, 1.0),
        ]
        for index in 1..<points.count {
            let lower = points[index - 1]
            let upper = points[index]
            guard clamped <= upper.contract else { continue }
            let span = upper.contract - lower.contract
            guard span > 0 else { return upper.position }
            let ratio = (clamped - lower.contract) / span
            return lower.position + ratio * (upper.position - lower.position)
        }
        return 1.0
    }

    static func logicMixerFaderPositionToContract(_ position: Double) -> Double {
        let clamped = min(max(position, 0.0), 1.0)
        let points: [(position: Double, contract: Double)] = [
            (0.0, 0.0),
            (0.1072961373390558, 0.2),
            (70.0 / 233.0, 0.4),
            (0.4206008583690987, 0.5),
            (0.48497854077253216, 0.6),
            (0.8111587982832618, 0.8),
            (1.0, 1.0),
        ]
        for index in 1..<points.count {
            let lower = points[index - 1]
            let upper = points[index]
            guard clamped <= upper.position else { continue }
            let span = upper.position - lower.position
            guard span > 0 else { return upper.contract }
            let ratio = (clamped - lower.position) / span
            return lower.contract + ratio * (upper.contract - lower.contract)
        }
        return 1.0
    }

    /// #107: target raw AX value for a desired public mixer volume contract,
    /// for the `AXIncrement`/`AXDecrement` nudge writer (Logic ignores `AXValue`
    /// writes on its faders). Mirrors `setLogicMixerFaderValue`'s contract→raw
    /// math without performing the (ineffective) write.
    static func logicMixerFaderContractToRaw(_ contract: Double, range: SliderRange) -> Double {
        let clamped = min(max(contract, 0.0), 1.0)
        let position = isLogicMixerRawFaderRange(range)
            ? logicMixerFaderContractToPosition(clamped)
            : clamped
        return range.min + position * (range.max - range.min)
    }

    /// #107: read a unipolar Logic track-header pan slider (live range 0...127,
    /// electrical center at the midpoint) as the public -1.0...1.0 pan contract.
    /// The header pan slider's `AXMinValue` is 0 (not negative), so the bipolar
    /// `extractCenteredSliderValue` can't be used here.
    static func headerPanContract(_ element: AXUIElement, range: SliderRange, runtime: AXHelpers.Runtime = .production) -> Double? {
        guard let raw = extractSliderValue(element, runtime: runtime) else { return nil }
        let center = (range.min + range.max) / 2.0
        let half = (range.max - range.min) / 2.0
        guard half > 0 else { return nil }
        return min(max((raw - center) / half, -1.0), 1.0)
    }

    /// Normalize a bipolar Logic AX slider to -1.0...1.0. Pan knobs in Logic
    /// 12.2 expose asymmetric integer ranges (-64...63); treating zero as
    /// the electrical center avoids surfacing a small false right-pan offset.
    static func extractCenteredSliderValue(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> Double? {
        guard let value = extractSliderValue(element, runtime: runtime),
              let range = extractSliderRange(element, runtime: runtime),
              range.min < 0.0,
              range.max > 0.0 else {
            return extractNormalizedSliderValue(element, runtime: runtime)
        }
        if value == 0.0 { return 0.0 }
        if value < 0.0 {
            return max(value / abs(range.min), -1.0)
        }
        return min(value / range.max, 1.0)
    }


    /// Read a track header and extract its basic state.
    ///
    /// WS3 AC2 (value-only honesty fix): `volume`/`pan`/`automationMode` now
    /// report the REAL track-header values instead of the fabricated
    /// `0.0`/`0.0`/`.off`. The `TrackState` type is UNCHANGED — the fields stay
    /// non-optional `Double`/`Double`/`AutomationMode` with no sentinel, no
    /// nullable, and no new enum case. On a rare AX-read failure each reader
    /// returns the SAME default the resource fabricated before this fix, so no
    /// new unreadable representation is introduced (the resource's existing
    /// `source`/`ax_occluded` fields already flag degraded reads). `volume`/`pan`
    /// use the identical header-fader readback the #107 write path uses, so
    /// `logic://tracks` and the mixer speak the same contract units.
    static func extractTrackState(
        from header: AXUIElement,
        index: Int,
        runtime: AXHelpers.Runtime = .production
    ) -> TrackState {
        let name = extractTrackName(from: header, runtime: runtime)
        let muted = extractTrackButtonState(from: header, prefix: "Mute", runtime: runtime) ?? false
        let soloed = extractTrackButtonState(from: header, prefix: "Solo", runtime: runtime) ?? false
        let armed = extractTrackButtonState(from: header, prefix: "Record", runtime: runtime) ?? false
        let selected = extractSelectedState(header, runtime: runtime) ?? false
        let trackType = inferTrackType(from: header, runtime: runtime)

        return TrackState(
            id: index,
            name: name,
            type: trackType,
            isMuted: muted,
            isSoloed: soloed,
            isArmed: armed,
            isSelected: selected,
            volume: extractTrackHeaderVolume(from: header, runtime: runtime),
            pan: extractTrackHeaderPan(from: header, runtime: runtime),
            automationMode: extractTrackAutomationMode(from: header, runtime: runtime),
            color: extractTrackColor(from: header, runtime: runtime)
        )
    }

    /// Real track-header volume as the public mixer contract (WS3 AC2). Reads
    /// the SAME per-track header fader the #107 write path drives, via
    /// `extractLogicMixerFaderValue`. Returns `0.0` (the pre-fix fabricated
    /// default) when the fader or its value is unreadable.
    private static func extractTrackHeaderVolume(
        from header: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Double {
        guard let fader = AXLogicProElements.findVolumeFader(in: header, runtime: runtime),
              let contract = extractLogicMixerFaderValue(fader, runtime: runtime) else {
            return 0.0
        }
        return contract
    }

    /// Real track-header pan as the public -1.0...1.0 contract (WS3 AC2). Uses
    /// the same `headerPanContract` mapping as the #107 write-path readback.
    /// Returns `0.0` (center — the pre-fix fabricated default) when the pan
    /// slider, its range, or its value is unreadable.
    private static func extractTrackHeaderPan(
        from header: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Double {
        guard let slider = AXLogicProElements.findPanControlInHeader(header, runtime: runtime),
              let range = extractSliderRange(slider, runtime: runtime),
              range.max > range.min,
              let contract = headerPanContract(slider, range: range, runtime: runtime) else {
            return 0.0
        }
        return contract
    }

    /// Real track-header automation mode (WS3 AC2). Scans the header for the
    /// automation control — gated by `automationModeContext` so unrelated
    /// "read"/"write" AX text cannot be misread — and maps its mode token to
    /// `AutomationMode`. Returns `.off` (the pre-fix fabricated default) when no
    /// automation control is found or its mode is unreadable; NO `.unknown` case
    /// is introduced.
    private static func extractTrackAutomationMode(
        from header: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AutomationMode {
        let elements = [header] + AXHelpers.findAllDescendants(of: header, maxDepth: 4, runtime: runtime)
        for element in elements {
            let combined = [
                AXHelpers.getDescription(element, runtime: runtime),
                AXHelpers.getTitle(element, runtime: runtime),
                extractTextValue(element, runtime: runtime),
            ].compactMap { $0?.lowercased() }.joined(separator: " ")
            guard AXLocalePolicy.automationModeContext.containsAny(in: combined) else { continue }
            if AXLocalePolicy.automationModeWrite.containsAny(in: combined) { return .write }
            if AXLocalePolicy.automationModeTrim.containsAny(in: combined) { return .trim }
            if AXLocalePolicy.automationModeTouch.containsAny(in: combined) { return .touch }
            if AXLocalePolicy.automationModeLatch.containsAny(in: combined) { return .latch }
            if AXLocalePolicy.automationModeRead.containsAny(in: combined) { return .read }
        }
        return .off
    }

    /// Read transport bar elements and build a TransportState.
    static func extractTransportState(
        from transport: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> TransportState {
        var state = TransportState()

        // Find and read transport button / checkbox states.
        let controls = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4, runtime: runtime)
            + AXHelpers.findAllDescendants(of: transport, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime)
        for control in controls {
            let desc = [
                AXHelpers.getDescription(control, runtime: runtime),
                AXHelpers.getTitle(control, runtime: runtime),
            ].compactMap { $0 }.joined(separator: " ")
            let pressed = extractButtonState(control, runtime: runtime) ?? false
            let descLower = desc.lowercased()

            if AXLocalePolicy.transportPlayControl.containsAny(in: descLower) {
                state.isPlaying = pressed
            } else if AXLocalePolicy.transportRecordControl.containsAny(in: descLower)
                && !AXLocalePolicy.transportRecordArmExclusion.containsAny(in: descLower) {
                state.isRecording = pressed
            } else if AXLocalePolicy.transportCycleControl.containsAny(in: descLower) {
                state.isCycleEnabled = pressed
            } else if AXLocalePolicy.transportMetronomeControl.containsAny(in: descLower) {
                state.isMetronomeEnabled = pressed
            }
        }

        // Find text fields / sliders for tempo and position.
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime)
            + AXHelpers.findAllDescendants(of: transport, role: kAXTextFieldRole, maxDepth: 4, runtime: runtime)
        for text in texts {
            guard let value = extractTextValue(text, runtime: runtime) else { continue }
            let desc = AXHelpers.getDescription(text, runtime: runtime) ?? ""
            let descLower = desc.lowercased()

            if AXLocalePolicy.tempoFieldLabel.containsAny(in: descLower) {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if AXLocalePolicy.playheadPositionFieldLabel.containsAny(in: descLower) || value.contains(".") && value.contains(":") == false {
                // Bar.Beat.Division.Tick format
                if value.filter({ $0 == "." }).count >= 2 {
                    state.position = value
                }
            } else if value.contains(":") {
                // Time format HH:MM:SS
                state.timePosition = value
            }
        }

        let sliders = AXHelpers.findAllDescendants(of: transport, role: kAXSliderRole, maxDepth: 4, runtime: runtime)
        var barValue: Int?
        var beatValue: Int?
        for slider in sliders {
            let desc = (AXHelpers.getDescription(slider, runtime: runtime) ?? "").lowercased()
            if AXLocalePolicy.tempoSliderContainsLabel.containsAny(in: desc), let tempo = extractSliderValue(slider, runtime: runtime) {
                state.tempo = tempo
            } else if AXLocalePolicy.barSliderLabel.containsAny(in: desc) {
                barValue = Int(extractSliderValue(slider, runtime: runtime) ?? 0)
            } else if AXLocalePolicy.beatSliderLabel.containsAny(in: desc) {
                beatValue = Int(extractSliderValue(slider, runtime: runtime) ?? 0)
            }
        }
        if let barValue, let beatValue {
            state.position = "\(barValue).\(beatValue).1.1"
        }

        state.lastUpdated = Date()
        return state
    }

    // MARK: - Private helpers

    private static func extractTrackName(from header: AXUIElement, runtime: AXHelpers.Runtime) -> String {
        // Logic 12.2 commonly exposes the authoritative live name on an
        // AXTextField's description while AXValue stays the numeric placeholder
        // "0". Prefer text-field metadata when it contains a real name; fall
        // back to static text only when the text-field path is empty/useless.
        let textFields = AXHelpers.findAllDescendants(
            of: header, role: kAXTextFieldRole, maxDepth: 3, runtime: runtime
        )
        for field in textFields {
            let candidates = [
                AXHelpers.getDescription(field, runtime: runtime),
                AXHelpers.getTitle(field, runtime: runtime),
                extractTextValue(field, runtime: runtime)
            ]
            for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                if !candidate.isEmpty, candidate != "0" {
                    return candidate
                }
            }
        }

        if let text = AXHelpers.findDescendant(
            of: header, role: kAXStaticTextRole, maxDepth: 3, runtime: runtime
        ),
           let name = extractTextValue(text, runtime: runtime)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        // AXLayoutItem headers commonly describe themselves as `4개의 ‘Holographic Squares’ 트랙`.
        if let desc = AXHelpers.getDescription(header, runtime: runtime),
           let quotedName = extractQuotedTrackName(from: desc) {
            return quotedName
        }

        if let title = AXHelpers.getTitle(header, runtime: runtime)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "Untitled"
    }

    private static func extractTrackButtonState(
        from header: AXUIElement,
        prefix: String,
        runtime: AXHelpers.Runtime
    ) -> Bool? {
        let localizedKeywords: [String: AXLocalePolicy.LabelSet] = [
            "Mute": AXLocalePolicy.trackMuteButton,
            "Solo": AXLocalePolicy.trackSoloButton,
            "Record": AXLocalePolicy.trackRecordButton
        ]
        let labels = localizedKeywords[prefix]
        let controls = AXHelpers.findAllDescendants(of: header, role: kAXButtonRole, maxDepth: 4, runtime: runtime)
            + AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime)
        for control in controls {
            let desc = (
                AXHelpers.getDescription(control, runtime: runtime)
                    ?? AXHelpers.getTitle(control, runtime: runtime)
                    ?? ""
            ).lowercased()
            let matched = labels?.containsAny(in: desc) ?? desc.contains(prefix.lowercased())
            if matched {
                return extractButtonState(control, runtime: runtime)
            }
        }
        return nil
    }

    private static func inferTrackType(from header: AXUIElement, runtime: AXHelpers.Runtime) -> TrackType {
        // Logic 12.2 often puts the human track name on the AXLayoutItem and
        // the type hint on a descendant icon/control, so scan both levels.
        var signals = [
            AXHelpers.getDescription(header, runtime: runtime),
            AXHelpers.getTitle(header, runtime: runtime),
            AXHelpers.getIdentifier(header, runtime: runtime),
            AXHelpers.getHelp(header, runtime: runtime),
            extractTrackName(from: header, runtime: runtime)
        ]
        let descendants = AXHelpers.findAllDescendants(of: header, maxDepth: 4, runtime: runtime)
        for element in descendants {
            signals.append(contentsOf: [
                AXHelpers.getDescription(element, runtime: runtime),
                AXHelpers.getTitle(element, runtime: runtime),
                AXHelpers.getIdentifier(element, runtime: runtime),
                AXHelpers.getHelp(element, runtime: runtime),
                extractTextValue(element, runtime: runtime)
            ])
        }
        let combined = signals
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // #131 — Logic's multichannel SMF open creates "GM Device N" channel
        // strips that route to a General-MIDI device and bounce SILENT. The
        // live AX header for these strips can carry an "audio"-shaped signal,
        // so this check MUST precede the `.audio` branch below or GM Device
        // strips get misclassified as audio tracks and the silent-bounce risk
        // is hidden before bounce. They are external-MIDI lanes, not audio.
        if AXLocalePolicy.trackTypeGMDevice.containsAny(in: combined) { return .externalMIDI }
        if AXLocalePolicy.trackTypeAudio.containsAny(in: combined) { return .audio }
        if AXLocalePolicy.trackTypeInstrument.containsAny(in: combined) { return .softwareInstrument }
        if AXLocalePolicy.trackTypeDrummer.containsAny(in: combined) { return .drummer }
        if AXLocalePolicy.trackTypeExternalMIDI.containsAny(in: combined) { return .externalMIDI }
        if AXLocalePolicy.trackTypeAux.containsAny(in: combined) { return .aux }
        if AXLocalePolicy.trackTypeBus.containsAny(in: combined) { return .bus }
        if AXLocalePolicy.trackTypeMaster.containsAny(in: combined) { return .master }
        return .unknown
    }

    private static func extractQuotedTrackName(from description: String) -> String? {
        let patterns = ["‘([^’]+)’", "'([^']+)'", "\"([^\"]+)\""]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)),
               let range = Range(match.range(at: 1), in: description) {
                let candidate = description[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func extractTrackColor(from header: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        // Logic Pro may expose color via a custom attribute or the element's description
        let desc = AXHelpers.getDescription(header, runtime: runtime) ?? ""
        if desc.lowercased().contains("color") {
            return desc
        }
        return nil
    }
}
