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
        // Some buttons use string "1"/"0"
        if let str = value as? String {
            return str == "1" || str.lowercased() == "true"
        }
        return nil
    }

    /// Extract checkbox state (a variant of button state, but checks kAXValueAttribute specifically).
    static func extractCheckboxState(_ element: AXUIElement, runtime: AXHelpers.Runtime = .production) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXValueAttribute, runtime: runtime) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
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

    /// Read a track header and extract its basic state.
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
            volume: 0.0,
            pan: 0.0,
            color: extractTrackColor(from: header, runtime: runtime)
        )
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
            let desc = AXHelpers.getDescription(control, runtime: runtime)
                ?? AXHelpers.getTitle(control, runtime: runtime)
                ?? ""
            let pressed = extractButtonState(control, runtime: runtime) ?? false
            let descLower = desc.lowercased()

            if descLower.contains("play") || descLower.contains("재생") {
                state.isPlaying = pressed
            } else if (descLower.contains("record") || descLower.contains("녹음")) && !descLower.contains("arm") && !descLower.contains("활성화") {
                state.isRecording = pressed
            } else if descLower.contains("cycle") || descLower.contains("loop") || descLower.contains("사이클") {
                state.isCycleEnabled = pressed
            } else if descLower.contains("metronome") || descLower.contains("click") || descLower.contains("메트로놈") || descLower.contains("클릭") {
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

            if descLower.contains("tempo") || descLower.contains("bpm") || descLower.contains("템포") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if descLower.contains("position") || descLower.contains("재생헤드 위치") || value.contains(".") && value.contains(":") == false {
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
            if (desc.contains("tempo") || desc.contains("템포")), let tempo = extractSliderValue(slider, runtime: runtime) {
                state.tempo = tempo
            } else if desc.contains("마디") || desc.contains("bar") {
                barValue = Int(extractSliderValue(slider, runtime: runtime) ?? 0)
            } else if desc.contains("비트") || desc.contains("beat") {
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
        // Try static text first.
        if let text = AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 3, runtime: runtime),
           let name = extractTextValue(text, runtime: runtime)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        // Text fields in live Logic often expose the track name via AXDescription, while AXValue is a numeric placeholder.
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 3, runtime: runtime) {
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
        let localizedKeywords: [String: [String]] = [
            "Mute": ["Mute", "음소거"],
            "Solo": ["Solo", "솔로"],
            "Record": ["Record", "Rec", "녹음 활성화", "레코드 활성화"]
        ]
        let keywords = localizedKeywords[prefix] ?? [prefix]
        let controls = AXHelpers.findAllDescendants(of: header, role: kAXButtonRole, maxDepth: 4, runtime: runtime)
            + AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime)
        for control in controls {
            let desc = (
                AXHelpers.getDescription(control, runtime: runtime)
                    ?? AXHelpers.getTitle(control, runtime: runtime)
                    ?? ""
            ).lowercased()
            if keywords.contains(where: { desc.contains($0.lowercased()) }) {
                return extractButtonState(control, runtime: runtime)
            }
        }
        return nil
    }

    private static func inferTrackType(from header: AXUIElement, runtime: AXHelpers.Runtime) -> TrackType {
        // Attempt to infer type from icon description or element identifiers.
        let desc = AXHelpers.getDescription(header, runtime: runtime)?.lowercased() ?? ""
        let title = AXHelpers.getTitle(header, runtime: runtime)?.lowercased() ?? ""
        let name = extractTrackName(from: header, runtime: runtime).lowercased()
        let combined = [desc, title, name].joined(separator: " ")

        if combined.contains("audio") || combined.contains("오디오") { return .audio }
        if combined.contains("instrument") || combined.contains("software") || combined.contains("악기") { return .softwareInstrument }
        if combined.contains("drummer") { return .drummer }
        if combined.contains("external") || combined.contains("midi") { return .externalMIDI }
        if combined.contains("aux") { return .aux }
        if combined.contains("bus") { return .bus }
        if combined.contains("master") || combined.contains("stereo out") { return .master }
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
