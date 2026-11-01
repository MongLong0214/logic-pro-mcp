import Foundation

struct SessionPlan: Codable, Sendable, Equatable {
    let schema: String
    let prompt: String
    let status: String
    let executionMode: String
    let parsedIntent: SessionParsedIntent
    let instrumentCatalog: SessionInstrumentCatalogStatus
    let sections: [SessionSectionPlan]
    let chordPlan: [SessionChordPlan]
    let trackPlan: [SessionTrackPlan]
    let workflowSteps: [SessionPlanWorkflowStep]
    let unsupportedOrRiskySteps: [SessionUnsupportedStep]
    let requiredConfirmations: [SessionPlanConfirmation]
    let toolSurfaceValidation: SessionToolSurfaceValidation
    let provenance: [SessionPlanProvenance]
    let nextSafeAction: String

    enum CodingKeys: String, CodingKey {
        case schema
        case prompt
        case status
        case executionMode = "execution_mode"
        case parsedIntent = "parsed_intent"
        case instrumentCatalog = "instrument_catalog"
        case sections
        case chordPlan = "chord_plan"
        case trackPlan = "track_plan"
        case workflowSteps = "workflow_steps"
        case unsupportedOrRiskySteps = "unsupported_or_risky_steps"
        case requiredConfirmations = "required_confirmations"
        case toolSurfaceValidation = "tool_surface_validation"
        case provenance
        case nextSafeAction = "next_safe_action"
    }
}

struct SessionParsedIntent: Codable, Sendable, Equatable {
    let tempoBPM: Int
    let key: String
    let scale: String
    let timeSignature: String
    let genre: String
    let mood: [String]
    let totalBars: Int
    let confidence: [String: String]

    enum CodingKeys: String, CodingKey {
        case tempoBPM = "tempo_bpm"
        case key
        case scale
        case timeSignature = "time_signature"
        case genre
        case mood
        case totalBars = "total_bars"
        case confidence
    }
}

struct SessionInstrumentCatalogStatus: Codable, Sendable, Equatable {
    let status: String
    let availableResources: [String]
    let missingResources: [String]
    let message: String

    enum CodingKeys: String, CodingKey {
        case status
        case availableResources = "available_resources"
        case missingResources = "missing_resources"
        case message
    }
}

struct SessionSectionPlan: Codable, Sendable, Equatable {
    let id: String
    let label: String
    let startBar: Int
    let lengthBars: Int
    let intent: String
    let provenance: String

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case startBar = "start_bar"
        case lengthBars = "length_bars"
        case intent
        case provenance
    }
}

struct SessionChordPlan: Codable, Sendable, Equatable {
    let bar: Int
    let chord: String
    let romanNumeral: String
    let durationBars: Int
    let provenance: String

    enum CodingKeys: String, CodingKey {
        case bar
        case chord
        case romanNumeral = "roman_numeral"
        case durationBars = "duration_bars"
        case provenance
    }
}

struct SessionTrackPlan: Codable, Sendable, Equatable {
    let id: String
    let role: String
    let suggestedInstrument: String
    let suggestionSource: String
    let confidence: String
    let catalogResource: String?
    let proposedTrackType: String
    let reason: String
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case suggestedInstrument = "suggested_instrument"
        case suggestionSource = "suggestion_source"
        case confidence
        case catalogResource = "catalog_resource"
        case proposedTrackType = "proposed_track_type"
        case reason
        case limitations
    }
}

struct SessionPlanWorkflowStep: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let tool: String?
    let command: String?
    let resource: String?
    let params: [String: String]
    let mutates: Bool
    let executed: Bool
    let requiresConfirmationLevel: String?
    let expectedResponseFields: [String]
    let rationale: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tool
        case command
        case resource
        case params
        case mutates
        case executed
        case requiresConfirmationLevel = "requires_confirmation_level"
        case expectedResponseFields = "expected_response_fields"
        case rationale
    }
}

struct SessionUnsupportedStep: Codable, Sendable, Equatable {
    let operation: String
    let reason: String
    let safeAlternative: String

    enum CodingKeys: String, CodingKey {
        case operation
        case reason
        case safeAlternative = "safe_alternative"
    }
}

struct SessionPlanConfirmation: Codable, Sendable, Equatable {
    let level: String
    let requiredFor: [String]
    let message: String

    enum CodingKeys: String, CodingKey {
        case level
        case requiredFor = "required_for"
        case message
    }
}

struct SessionToolSurfaceValidation: Codable, Sendable, Equatable {
    let isValid: Bool
    let checkedCommands: [String]
    let issues: [String]

    enum CodingKeys: String, CodingKey {
        case isValid = "is_valid"
        case checkedCommands = "checked_commands"
        case issues
    }
}

struct SessionPlanProvenance: Codable, Sendable, Equatable {
    let field: String
    let source: String
    let confidence: String
}

enum SessionPlanGenerator {
    static let schema = "logic_pro_mcp_session_plan.v1"

    static func plan(prompt rawPrompt: String) -> SessionPlan {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        let catalog = instrumentCatalogStatus()

        guard !prompt.isEmpty else {
            let intent = SessionParsedIntent(
                tempoBPM: 100,
                key: "C",
                scale: "minor",
                timeSignature: "4/4",
                genre: "unspecified",
                mood: [],
                totalBars: 8,
                confidence: [
                    "tempo_bpm": "default",
                    "key": "default",
                    "scale": "default",
                    "time_signature": "default",
                    "genre": "default",
                    "total_bars": "default",
                ]
            )
            return buildPlan(
                prompt: prompt,
                status: "unsupported",
                intent: intent,
                catalog: catalog,
                unsupported: [
                    SessionUnsupportedStep(
                        operation: "empty_prompt",
                        reason: "A non-empty musical prompt is required for session planning.",
                        safeAlternative: "Session planning terminated because no musical prompt was supplied; no tool or project action was attempted and no human intervention was requested."
                    ),
                ],
                terminal: true
            )
        }

        let intent = parseIntent(prompt: prompt)
        var unsupported = baseUnsupportedSteps()
        unsupported.append(contentsOf: thirdPartyUnsupportedSteps(lower))
        if lower.contains("chord track") {
            unsupported.append(SessionUnsupportedStep(
                operation: "direct_chord_track_edit",
                reason: "This MCP build does not expose direct Chord Track mutation.",
                safeAlternative: "Use the chord_plan as planning metadata and write MIDI only after explicit confirmation."
            ))
        }

        let status = catalog.status == "available" && unsupported.count == baseUnsupportedSteps().count ? "planned" : "degraded"
        return buildPlan(
            prompt: prompt,
            status: status,
            intent: intent,
            catalog: catalog,
            unsupported: unsupported
        )
    }

    static func parseIntent(prompt: String) -> SessionParsedIntent {
        let lower = prompt.lowercased()
        var confidence: [String: String] = [:]

        let genre = detectGenre(lower)
        confidence["genre"] = genre == "unspecified" ? "default" : "prompt"

        let tempo: Int
        if let capturedTempo = capture(#"(?<!\d)(\d{1,4})\s*bpm\b"#, in: lower).first,
           let bpm = Int(capturedTempo),
           (40...240).contains(bpm) {
            tempo = bpm
            confidence["tempo_bpm"] = "prompt"
        } else {
            tempo = defaultTempo(for: genre)
            confidence["tempo_bpm"] = "genre_default"
        }

        let bars: Int
        if let capturedBars = capture(#"\b(\d{1,3})\s*[- ]?\s*bars?\b"#, in: lower).first,
           let parsedBars = Int(capturedBars),
           (1...128).contains(parsedBars) {
            bars = parsedBars
            confidence["total_bars"] = "prompt"
        } else {
            bars = 16
            confidence["total_bars"] = "default"
        }

        let keyScale = detectKeyAndScale(prompt)
        confidence["key"] = keyScale.source
        confidence["scale"] = keyScale.source

        let timeSignature: String
        if let capturedTime = capture(#"\b(\d{1,2}/\d{1,2})\b"#, in: prompt).first,
           isValidTimeSignature(capturedTime) {
            timeSignature = capturedTime
            confidence["time_signature"] = "prompt"
        } else {
            timeSignature = "4/4"
            confidence["time_signature"] = "default"
        }

        return SessionParsedIntent(
            tempoBPM: tempo,
            key: keyScale.key,
            scale: keyScale.scale,
            timeSignature: timeSignature,
            genre: genre,
            mood: detectMood(lower),
            totalBars: bars,
            confidence: confidence
        )
    }

    static func sections(for totalBars: Int, genre: String) -> [SessionSectionPlan] {
        if totalBars <= 8 {
            return [
                SessionSectionPlan(
                    id: "section.loop",
                    label: "Loop",
                    startBar: 1,
                    lengthBars: totalBars,
                    intent: "\(genre) core groove",
                    provenance: "heuristic"
                ),
            ]
        }

        if totalBars == 16 {
            return [
                section("intro", "Intro", 1, 4, "Establish pulse and harmonic identity"),
                section("a", "Groove A", 5, 8, "Main motif and full rhythm section"),
                section("turnaround", "Turnaround", 13, 4, "Variation or fill leading back to loop"),
            ]
        }

        if totalBars >= 32 {
            return [
                section("intro", "Intro", 1, 4, "Establish texture"),
                section("a", "Section A", 5, 8, "Main theme"),
                section("b", "Section B", 13, 8, "Contrast or lift"),
                section("build", "Build", 21, 8, "Add intensity and register"),
                section("outro", "Outro", 29, max(4, totalBars - 28), "Resolve or loop out"),
            ]
        }

        var result: [SessionSectionPlan] = []
        var start = 1
        var index = 1
        while start <= totalBars {
            let length = min(4, totalBars - start + 1)
            result.append(section("part_\(index)", "Part \(index)", start, length, "Four-bar phrase block"))
            start += length
            index += 1
        }
        return result
    }

    static func chordPlan(for intent: SessionParsedIntent) -> [SessionChordPlan] {
        let progression = chordProgression(key: intent.key, scale: intent.scale)
        return (0..<intent.totalBars).map { offset in
            let chord = progression[offset % progression.count]
            return SessionChordPlan(
                bar: offset + 1,
                chord: chord.symbol,
                romanNumeral: chord.roman,
                durationBars: 1,
                provenance: "heuristic_\(intent.scale)_diatonic_loop"
            )
        }
    }

    static func trackPlan(for prompt: String, intent: SessionParsedIntent, catalog: SessionInstrumentCatalogStatus) -> [SessionTrackPlan] {
        roles(for: prompt, genre: intent.genre).enumerated().map { index, role in
            track(role: role, index: index + 1, catalog: catalog)
        }
    }

    static func validateWorkflowSteps(_ steps: [SessionPlanWorkflowStep]) -> SessionToolSurfaceValidation {
        var checked: [String] = []
        var issues: [String] = []

        for step in steps {
            guard let tool = step.tool, let command = step.command else { continue }
            let key = "\(tool).\(command)"
            checked.append(key)
            if WorkflowSkillCatalog.publicCommands[tool]?.contains(command) != true {
                issues.append("unknown public command: \(key)")
            }
            if step.mutates && step.requiresConfirmationLevel == nil {
                issues.append("mutating step \(step.id) lacks confirmation metadata")
            }
            if step.executed {
                issues.append("planning-only step \(step.id) must not be marked executed")
            }
        }

        return SessionToolSurfaceValidation(
            isValid: issues.isEmpty,
            checkedCommands: checked.sorted(),
            issues: issues
        )
    }

    private static func buildPlan(
        prompt: String,
        status: String,
        intent: SessionParsedIntent,
        catalog: SessionInstrumentCatalogStatus,
        unsupported: [SessionUnsupportedStep],
        terminal: Bool = false
    ) -> SessionPlan {
        let sections = sections(for: intent.totalBars, genre: intent.genre)
        let chords = chordPlan(for: intent)
        let tracks = trackPlan(for: prompt, intent: intent, catalog: catalog)
        let steps = terminal ? [] : workflowSteps(for: intent, tracks: tracks)
        let validation = validateWorkflowSteps(steps)

        return SessionPlan(
            schema: schema,
            prompt: prompt,
            status: validation.isValid ? status : "unsupported",
            executionMode: "dry_run_only",
            parsedIntent: intent,
            instrumentCatalog: catalog,
            sections: sections,
            chordPlan: chords,
            trackPlan: tracks,
            workflowSteps: steps,
            unsupportedOrRiskySteps: unsupported,
            requiredConfirmations: confirmations(for: steps),
            toolSurfaceValidation: validation,
            provenance: [
                SessionPlanProvenance(field: "parsed_intent", source: "prompt_plus_heuristics", confidence: "mixed"),
                SessionPlanProvenance(field: "sections", source: "deterministic_arrangement_heuristic", confidence: "medium"),
                SessionPlanProvenance(field: "chord_plan", source: "diatonic_progression_heuristic", confidence: "medium"),
                SessionPlanProvenance(field: "workflow_steps", source: "current_mcp_public_command_census", confidence: "high"),
            ],
            nextSafeAction: terminal ? "none_terminal" : "review_plan"
        )
    }

    private static func workflowSteps(for intent: SessionParsedIntent, tracks: [SessionTrackPlan]) -> [SessionPlanWorkflowStep] {
        var steps: [SessionPlanWorkflowStep] = [
            readStep("read_health", "Read MCP and Logic health", "logic://system/health", ["channels", "permissions"]),
            readStep("read_project", "Read current project metadata", "logic://project/info", ["data", "source"]),
            readStep("read_tracks", "Read current tracks before any optional mutation", "logic://tracks", ["data"]),
            toolStep(
                "propose_tempo",
                "Optionally set project tempo after plan review",
                "logic_transport",
                "set_tempo",
                ["tempo": "\(intent.tempoBPM)"],
                true,
                "L1",
                ["success", "verified"],
                "Tempo write is proposed only; this resource does not call the tool."
            ),
        ]

        for track in tracks {
            if track.proposedTrackType == "drummer" {
                steps.append(toolStep(
                    "propose_create_\(track.id)",
                    "Optionally create \(track.role) Drummer track",
                    "logic_tracks",
                    "create_drummer",
                    [:],
                    true,
                    "L1",
                    ["success", "verified", "created_track"],
                    "Track creation is proposed only and requires user confirmation."
                ))
            } else {
                steps.append(toolStep(
                    "propose_create_\(track.id)",
                    "Optionally create \(track.role) software instrument track",
                    "logic_tracks",
                    "create_instrument",
                    [:],
                    true,
                    "L1",
                    ["success", "verified", "created_track"],
                    "Track creation is proposed only and requires user confirmation."
                ))
                steps.append(toolStep(
                    "propose_assign_\(track.id)",
                    "Optionally assign \(track.suggestedInstrument)",
                    "logic_tracks",
                    "set_instrument",
                    ["path": track.suggestedInstrument],
                    true,
                    "L1",
                    ["success", "verified"],
                    "Instrument assignment must be attempted only after resolving a valid library path."
                ))
            }
        }

        steps.append(toolStep(
            "propose_import_midi",
            "Optionally import caller-generated MIDI after review",
            "logic_midi",
            "import_file",
            ["source": "caller_generated_smf", "bar": "1"],
            true,
            "L1",
            ["success", "verified"],
            "This planner does not generate or import a MIDI file; it only proposes a later guarded step."
        ))
        return steps
    }

    private static func confirmations(for steps: [SessionPlanWorkflowStep]) -> [SessionPlanConfirmation] {
        let l1 = Set(steps.compactMap { step in
            step.mutates && step.requiresConfirmationLevel == "L1" ? step.command : nil
        }).sorted()
        guard !l1.isEmpty else { return [] }
        return [
            SessionPlanConfirmation(
                level: "L1",
                requiredFor: l1,
                message: "Review the dry-run plan, target project, target tracks, generated MIDI, and readback expectations before any mutation."
            ),
        ]
    }

    private static func readStep(_ id: String, _ title: String, _ resource: String, _ fields: [String]) -> SessionPlanWorkflowStep {
        SessionPlanWorkflowStep(
            id: id,
            title: title,
            tool: nil,
            command: nil,
            resource: resource,
            params: [:],
            mutates: false,
            executed: false,
            requiresConfirmationLevel: nil,
            expectedResponseFields: fields,
            rationale: "Read-only context required before deciding whether to execute the plan."
        )
    }

    private static func toolStep(
        _ id: String,
        _ title: String,
        _ tool: String,
        _ command: String,
        _ params: [String: String],
        _ mutates: Bool,
        _ level: String?,
        _ fields: [String],
        _ rationale: String
    ) -> SessionPlanWorkflowStep {
        SessionPlanWorkflowStep(
            id: id,
            title: title,
            tool: tool,
            command: command,
            resource: nil,
            params: params,
            mutates: mutates,
            executed: false,
            requiresConfirmationLevel: level,
            expectedResponseFields: fields,
            rationale: rationale
        )
    }

    private static func instrumentCatalogStatus() -> SessionInstrumentCatalogStatus {
        let staticResources = Set(ResourceProvider.resources.map(\.uri))
        let templates = Set(ResourceProvider.templates.map(\.uriTemplate))
        let required = [
            "logic://stock-instruments",
            "logic://session-players",
            "logic://stock-instruments/{id}",
            "logic://session-players/{id}",
        ]
        let available = required.filter { staticResources.contains($0) || templates.contains($0) }
        let missing = required.filter { !available.contains($0) }
        return SessionInstrumentCatalogStatus(
            status: missing.isEmpty ? "available" : "degraded_unavailable",
            availableResources: available,
            missingResources: missing,
            message: missing.isEmpty
                ? "Issue #31 instrument catalog resources are available for catalog-backed suggestions."
                : "Issue #31 instrument catalog resources are not served by this build; suggestions are heuristic and explicitly degraded."
        )
    }

    private static func detectGenre(_ lower: String) -> String {
        let genres: [(String, [String])] = [
            ("lo-fi", ["lo-fi", "lofi"]),
            ("hip hop", ["hip hop", "hip-hop", "boom bap"]),
            ("cinematic", ["cinematic", "film", "score", "cue"]),
            ("funk", ["funk"]),
            ("techno", ["techno"]),
            ("house", ["house"]),
            ("ambient", ["ambient"]),
            ("rock", ["rock"]),
            ("pop", ["pop"]),
            ("jazz", ["jazz"]),
            ("trap", ["trap"]),
        ]
        return genres.first { _, aliases in aliases.contains { lower.contains($0) } }?.0 ?? "unspecified"
    }

    private static func defaultTempo(for genre: String) -> Int {
        switch genre {
        case "lo-fi": return 75
        case "hip hop": return 88
        case "cinematic": return 90
        case "funk": return 110
        case "techno": return 140
        case "house": return 124
        case "ambient": return 80
        case "trap": return 140
        default: return 100
        }
    }

    private static func detectMood(_ lower: String) -> [String] {
        // Word-boundary match so unrelated words ("software", "warmth") cannot inject
        // a phantom mood the user never expressed.
        let moods = ["dark", "bright", "warm", "aggressive", "soft", "dreamy", "uplifting", "moody", "minimal"]
        return moods.filter { mood in
            !capture(#"\b("# + mood + #")\b"#, in: lower).isEmpty
        }
    }

    private static func isValidTimeSignature(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let numerator = Int(parts[0]),
              let denominator = Int(parts[1]) else {
            return false
        }
        return numerator > 0 && [1, 2, 4, 8, 16].contains(denominator)
    }

    private static func detectKeyAndScale(_ prompt: String) -> (key: String, scale: String, source: String) {
        // Require an explicit "in <key> <scale>" form so adjectives ending in a note
        // letter (harmonic/melodic/dramatic minor) cannot produce a phantom key with
        // high "prompt" confidence. A leading \b and a mandatory separator stop the
        // note-letter from being clipped out of the middle of a word.
        let pattern = #"\bin\s+([A-Ga-g](?:#|b|♭)?)[ -](major|minor|maj|min)\b"#
        let captures = capture(pattern, in: prompt)
        guard captures.count >= 2 else {
            return ("C", "minor", "default")
        }
        let key = normalizeKey(captures[0])
        let scale = captures[1].lowercased().hasPrefix("maj") ? "major" : "minor"
        return (key, scale, "prompt")
    }

    private static func roles(for prompt: String, genre: String) -> [String] {
        let lower = prompt.lowercased()
        var roles: [String] = []
        func add(_ role: String) {
            if !roles.contains(role) { roles.append(role) }
        }

        if lower.contains("drum") || lower.contains("beat") || lower.contains("kick") { add("drums") }
        if lower.contains("percussion") { add("percussion") }
        if lower.contains("bass") { add("bass") }
        if lower.contains("guitar") { add("guitar") }
        if lower.contains("keys") || lower.contains("piano") || lower.contains("keyboard") { add("keys") }
        if lower.contains("string") { add("strings") }
        if lower.contains("brass") || lower.contains("horn") { add("brass") }
        if lower.contains("pad") { add("pad") }
        if lower.contains("synth") || lower.contains("lead") { add("synth") }

        if roles.isEmpty {
            switch genre {
            case "cinematic":
                roles = ["strings", "brass", "percussion"]
            case "funk":
                roles = ["drums", "bass", "guitar", "keys"]
            case "lo-fi", "hip hop":
                roles = ["drums", "bass", "keys"]
            case "techno", "house", "trap":
                roles = ["drums", "bass", "synth"]
            default:
                roles = ["drums", "bass", "keys"]
            }
        }
        return roles
    }

    private static func track(role: String, index: Int, catalog: SessionInstrumentCatalogStatus) -> SessionTrackPlan {
        let source = catalog.status == "available" ? "catalog_reference" : "heuristic_degraded"
        let confidence = catalog.status == "available" ? "medium" : "low"
        let spec: (instrument: String, resource: String?, type: String, limitations: [String])
        switch role {
        case "drums":
            spec = ("Drummer", "logic://session-players/logic.session_player.drummer", "drummer", ["Drummer performance controls are not directly editable by this plan."])
        case "percussion":
            spec = ("Drum Machine Designer", "logic://stock-instruments/logic.stock.instrument.drum_machine_designer", "software_instrument", [])
        case "bass":
            spec = ("Studio Bass", "logic://stock-instruments/logic.stock.instrument.studio_bass", "software_instrument", [])
        case "guitar":
            spec = ("Unresolved guitar instrument", nil, "software_instrument", ["No catalog-backed stock guitar instrument is available in this build."])
        case "keys":
            spec = ("Vintage Electric Piano", "logic://stock-instruments/logic.stock.instrument.vintage_electric_piano", "software_instrument", [])
        case "strings":
            spec = ("Studio Strings", "logic://stock-instruments/logic.stock.instrument.studio_strings", "software_instrument", [])
        case "brass":
            spec = ("Studio Horns", "logic://stock-instruments/logic.stock.instrument.studio_horns", "software_instrument", [])
        case "pad", "synth":
            spec = ("Alchemy", "logic://stock-instruments/logic.stock.instrument.alchemy", "software_instrument", [])
        default:
            spec = ("Software Instrument", nil, "software_instrument", ["Role has no specific catalog-backed instrument suggestion."])
        }

        return SessionTrackPlan(
            id: "track_\(index)_\(role.replacingOccurrences(of: " ", with: "_"))",
            role: role,
            suggestedInstrument: spec.instrument,
            suggestionSource: source,
            confidence: confidence,
            catalogResource: spec.resource,
            proposedTrackType: spec.type,
            reason: "Matched role '\(role)' from prompt or genre heuristic.",
            limitations: spec.limitations + (catalog.status == "available" ? [] : ["Instrument catalog #31 is unavailable in this build; automatic patch assignment is unavailable."])
        )
    }

    private static func baseUnsupportedSteps() -> [SessionUnsupportedStep] {
        [
            SessionUnsupportedStep(
                operation: "execute_plan",
                reason: "This resource is planning-only and never calls mutating tools.",
                safeAlternative: "Review the plan, then call individual MCP tools with explicit confirmations."
            ),
            SessionUnsupportedStep(
                operation: "automatic_preset_loading",
                reason: "Arbitrary preset loading is not verified by this dry-run resource.",
                safeAlternative: "Resolve a library path first, then use logic_tracks.set_instrument only after confirmation and readback planning."
            ),
        ]
    }

    private static func thirdPartyUnsupportedSteps(_ lower: String) -> [SessionUnsupportedStep] {
        let names = ["serum", "kontakt", "omnisphere", "vital", "fabfilter", "third-party", "third party"]
        guard names.contains(where: { lower.contains($0) }) else { return [] }
        return [
            SessionUnsupportedStep(
                operation: "third_party_plugin_or_instrument",
                reason: "This planner only references current Logic Pro MCP public surfaces and does not recommend third-party plugins without catalog provenance.",
                safeAlternative: "Only stock instruments present in the provenance-backed catalog are available; other requests terminate unsupported."
            ),
        ]
    }

    private static func section(_ id: String, _ label: String, _ start: Int, _ length: Int, _ intent: String) -> SessionSectionPlan {
        SessionSectionPlan(id: "section.\(id)", label: label, startBar: start, lengthBars: length, intent: intent, provenance: "heuristic")
    }

    private static func chordProgression(key: String, scale: String) -> [(symbol: String, roman: String)] {
        if scale == "major" {
            return [
                (chord(key, minor: false), "I"),
                (chord(transpose(key, by: 7), minor: false), "V"),
                (chord(transpose(key, by: 9), minor: true), "vi"),
                (chord(transpose(key, by: 5), minor: false), "IV"),
            ]
        }
        return [
            (chord(key, minor: true), "i"),
            (chord(transpose(key, by: 8), minor: false), "VI"),
            (chord(transpose(key, by: 3), minor: false), "III"),
            (chord(transpose(key, by: 10), minor: false), "VII"),
        ]
    }

    private static func chord(_ root: String, minor: Bool) -> String {
        minor ? "\(root)m" : root
    }

    private static func transpose(_ key: String, by semitones: Int) -> String {
        let normalized = normalizeKey(key)
        let preferFlats = normalized.contains("b") || ["F", "Bb", "Eb", "Ab", "Db", "Gb"].contains(normalized)
        let names = preferFlats
            ? ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
            : ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let next = (pitchClass(normalized) + semitones + 12) % 12
        return names[next]
    }

    private static func pitchClass(_ key: String) -> Int {
        [
            "C": 0, "B#": 0,
            "C#": 1, "Db": 1,
            "D": 2,
            "D#": 3, "Eb": 3,
            "E": 4, "Fb": 4,
            "F": 5, "E#": 5,
            "F#": 6, "Gb": 6,
            "G": 7,
            "G#": 8, "Ab": 8,
            "A": 9,
            "A#": 10, "Bb": 10,
            "B": 11, "Cb": 11,
        ][normalizeKey(key), default: 0]
    }

    private static func normalizeKey(_ raw: String) -> String {
        let replaced = raw.replacingOccurrences(of: "♭", with: "b")
        guard let first = replaced.first else { return "C" }
        return String(first).uppercased() + replaced.dropFirst()
    }

    private static func capture(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            let matchRange = match.range(at: index)
            guard let range = Range(matchRange, in: text) else { return nil }
            return String(text[range])
        }
    }
}
