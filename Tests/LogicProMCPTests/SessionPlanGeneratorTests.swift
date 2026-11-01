import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func sessionPlanResourceObject(_ uri: String) async throws -> [String: Any] {
    let result = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
    return try #require(sharedJSONObject(sharedResourceText(result)))
}

private func sessionPlanResourceError(_ uri: String) async -> Error? {
    do {
        _ = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
        return nil
    } catch {
        return error
    }
}

@Suite("Session plan generator — parsing")
struct SessionPlanParsingTests {
    @Test("extracts tempo, key, scale, genre, and bar count from funk prompt")
    func extractsFunkIntent() {
        let intent = SessionPlanGenerator.parseIntent(prompt: "16-bar funk in E minor at 110 BPM with drums, bass, guitar, and keys")

        #expect(intent.tempoBPM == 110)
        #expect(intent.key == "E")
        #expect(intent.scale == "minor")
        #expect(intent.genre == "funk")
        #expect(intent.totalBars == 16)
        #expect(intent.timeSignature == "4/4")
        #expect(intent.confidence["tempo_bpm"] == "prompt")
    }

    @Test("extracts flat major keys and lo-fi defaults")
    func extractsFlatMajorIntent() {
        let intent = SessionPlanGenerator.parseIntent(prompt: "8-bar lo-fi loop at 75 BPM in Bb major")

        #expect(intent.tempoBPM == 75)
        #expect(intent.key == "Bb")
        #expect(intent.scale == "major")
        #expect(intent.genre == "lo-fi")
        #expect(intent.totalBars == 8)
    }

    @Test("uses genre defaults when prompt omits tempo")
    func genreDefaultTempo() {
        let intent = SessionPlanGenerator.parseIntent(prompt: "32-bar cinematic cue in D minor with strings, brass, and percussion")

        #expect(intent.tempoBPM == 90)
        #expect(intent.confidence["tempo_bpm"] == "genre_default")
        #expect(intent.genre == "cinematic")
        #expect(intent.key == "D")
        #expect(intent.scale == "minor")
    }

    @Test("tempo extraction is case-insensitive and honors mixed-case BPM")
    func tempoCaseInsensitive() {
        let intent = SessionPlanGenerator.parseIntent(prompt: "techno at 100 Bpm")

        #expect(intent.tempoBPM == 100)
        #expect(intent.confidence["tempo_bpm"] == "prompt")
    }

    @Test("out-of-range tempo falls back to the genre default, never false prompt confidence")
    func tempoOutOfRangeFallsBack() {
        // 140 is the techno genre default; the explicit (out-of-range) tempo must be dropped.
        let truncated = SessionPlanGenerator.parseIntent(prompt: "1200 BPM techno")
        #expect(truncated.tempoBPM == 140)
        #expect(truncated.confidence["tempo_bpm"] == "genre_default")

        let tooFast = SessionPlanGenerator.parseIntent(prompt: "make it 300 bpm techno")
        #expect(tooFast.tempoBPM == 140)
        #expect(tooFast.confidence["tempo_bpm"] == "genre_default")
    }

    @Test("adjectives ending in a note letter never produce a phantom key")
    func phantomKeyRejected() {
        for prompt in ["harmonic minor lead", "a dramatic minor piece", "melodic minor", "epic major cue"] {
            let intent = SessionPlanGenerator.parseIntent(prompt: prompt)
            #expect(intent.confidence["key"] == "default", "\(prompt) must not yield prompt-confidence key")
            #expect(intent.confidence["scale"] == "default", "\(prompt) must not yield prompt-confidence scale")
            #expect(intent.key == "C")
            #expect(intent.scale == "minor")
        }
    }

    @Test("bar regex anchors so substrings and word prefixes do not match")
    func barRegexAnchored() {
        let prefix = SessionPlanGenerator.parseIntent(prompt: "make it 8 barely audible bars")
        #expect(prefix.totalBars == 16)
        #expect(prefix.confidence["total_bars"] == "default")

        let digitSubstring = SessionPlanGenerator.parseIntent(prompt: "1280 bars of funk")
        #expect(digitSubstring.totalBars == 16)
        #expect(digitSubstring.confidence["total_bars"] == "default")

        let barreCollision = SessionPlanGenerator.parseIntent(prompt: "120 barre chords over 16 bars")
        #expect(barreCollision.totalBars == 16)
        #expect(barreCollision.confidence["total_bars"] == "prompt")

        let plain = SessionPlanGenerator.parseIntent(prompt: "32 bars of techno")
        #expect(plain.totalBars == 32)
        #expect(plain.confidence["total_bars"] == "prompt")
    }

    @Test("invalid time signatures fall back to 4/4 with default confidence")
    func invalidTimeSignatureFallsBack() {
        let zeroDenominator = SessionPlanGenerator.parseIntent(prompt: "funk in 7/0 time")
        #expect(zeroDenominator.timeSignature == "4/4")
        #expect(zeroDenominator.confidence["time_signature"] == "default")

        let nonsense = SessionPlanGenerator.parseIntent(prompt: "99/99 time funk")
        #expect(nonsense.timeSignature == "4/4")
        #expect(nonsense.confidence["time_signature"] == "default")

        let valid = SessionPlanGenerator.parseIntent(prompt: "waltz in 3/4 time")
        #expect(valid.timeSignature == "3/4")
        #expect(valid.confidence["time_signature"] == "prompt")
    }

    @Test("mood detection matches whole words only")
    func moodWordBoundary() {
        #expect(SessionPlanGenerator.parseIntent(prompt: "a software synth track").mood.isEmpty)
        #expect(SessionPlanGenerator.parseIntent(prompt: "warmth pads everywhere").mood.isEmpty)
        #expect(SessionPlanGenerator.parseIntent(prompt: "soft warm dreamy pad").mood == ["warm", "soft", "dreamy"])
    }
}

@Suite("Session plan generator — arrangement")
struct SessionPlanArrangementTests {
    @Test("generates sections for 16-bar and 32-bar prompts")
    func sectionGeneration() {
        let sixteen = SessionPlanGenerator.sections(for: 16, genre: "funk")
        #expect(sixteen.map(\.label) == ["Intro", "Groove A", "Turnaround"])
        #expect(sixteen.last?.startBar == 13)

        let thirtyTwo = SessionPlanGenerator.sections(for: 32, genre: "cinematic")
        #expect(thirtyTwo.map(\.label).contains("Build"))
        #expect(thirtyTwo.last?.startBar == 29)
    }

    @Test("generates deterministic minor and major chord plans")
    func chordPlanGeneration() {
        let minor = SessionPlanGenerator.parseIntent(prompt: "4-bar funk in E minor at 110 BPM")
        let minorChords = SessionPlanGenerator.chordPlan(for: minor).prefix(4).map(\.chord)
        #expect(Array(minorChords) == ["Em", "C", "G", "D"])

        let major = SessionPlanGenerator.parseIntent(prompt: "4-bar lo-fi in Bb major at 75 BPM")
        let majorChords = SessionPlanGenerator.chordPlan(for: major).prefix(4).map(\.chord)
        #expect(Array(majorChords) == ["Bb", "F", "Gm", "Eb"])
    }

    @Test("track plan uses the issue 31 catalog when those resources are registered")
    func trackPlanUsesCatalogWhenPresent() {
        // Integrated build: the issue #31 stock-instrument / Session Player resources are
        // registered in ResourceProvider, so the planner produces catalog-backed suggestions
        // rather than the degraded heuristic fallback.
        let plan = SessionPlanGenerator.plan(prompt: "16-bar funk in E minor at 110 BPM with drums, bass, guitar, and keys")

        #expect(plan.instrumentCatalog.status == "available")
        #expect(plan.trackPlan.contains { $0.role == "drums" && $0.proposedTrackType == "drummer" })
        // Guitar still has no catalog-backed stock instrument, so its resource stays nil even when the catalog is available.
        #expect(plan.trackPlan.contains { $0.role == "guitar" && $0.catalogResource == nil })
        #expect(plan.trackPlan.allSatisfy { $0.suggestionSource == "catalog_reference" })
    }

    @Test("every catalog resource the planner emits resolves to a real issue-31 catalog entry")
    func plannerCatalogResourcesResolve() {
        // Locks the #97->#96 linkage: a rename of a stock-instrument / Session Player
        // entry ID must break this test rather than ship a session plan that points
        // clients at a catalog resource that fails closed on read.
        let validIDs = Set(
            StockInstrumentCatalog.stockInstrumentSnapshot.entries.map(\.id)
                + StockInstrumentCatalog.sessionPlayerSnapshot.entries.map(\.id)
        )
        let plan = SessionPlanGenerator.plan(
            prompt: "16-bar orchestral funk with drums, percussion, bass, guitar, keys, strings, brass, pad, and synth at 110 BPM in E minor"
        )
        let referenced = plan.trackPlan.compactMap(\.catalogResource)
        #expect(!referenced.isEmpty)
        for uri in referenced {
            let id = String(uri.split(separator: "/").last ?? "")
            #expect(validIDs.contains(id), "session plan references catalog entry '\(id)' (\(uri)) absent from the issue-31 catalog")
        }
    }
}

@Suite("Session plan generator — safety")
struct SessionPlanSafetyTests {
    @Test("workflow steps validate against the public command surface")
    func proposedCommandsValidate() {
        let plan = SessionPlanGenerator.plan(prompt: "8-bar techno in A minor at 140 BPM with drums, bass, and synth")

        #expect(plan.toolSurfaceValidation.isValid)
        #expect(plan.toolSurfaceValidation.checkedCommands.contains("logic_transport.set_tempo"))
        #expect(plan.toolSurfaceValidation.checkedCommands.contains("logic_tracks.create_instrument"))
        #expect(plan.toolSurfaceValidation.checkedCommands.contains("logic_midi.import_file"))
        #expect(plan.workflowSteps.filter(\.mutates).allSatisfy { $0.requiresConfirmationLevel == "L1" })
    }

    @Test("planning-only resource never marks proposed tool steps as executed")
    func noMutationGuarantee() {
        let plan = SessionPlanGenerator.plan(prompt: "16-bar funk in E minor at 110 BPM with drums, bass, guitar, and keys")

        #expect(plan.executionMode == "dry_run_only")
        #expect(plan.workflowSteps.allSatisfy { !$0.executed })
        #expect(plan.workflowSteps.contains { $0.mutates })
        #expect(plan.nextSafeAction == "review_plan")
    }

    @Test("third-party plugin requests are reported as unsupported")
    func unsupportedThirdPartyReported() {
        let plan = SessionPlanGenerator.plan(prompt: "8-bar house track in A minor with Serum bass")

        let unsupported = plan.unsupportedOrRiskySteps.first { $0.operation == "third_party_plugin_or_instrument" }
        #expect(unsupported != nil)
        #expect(unsupported?.safeAlternative == "Only stock instruments present in the provenance-backed catalog are available; other requests terminate unsupported.")
        #expect(plan.unsupportedOrRiskySteps.contains { $0.operation == "execute_plan" })
    }

    @Test("missing instrument catalog is a terminal limitation, not a human fallback")
    func missingCatalogTerminatesWithoutHumanFallback() throws {
        let intent = SessionPlanGenerator.parseIntent(prompt: "8-bar funk with guitar")
        let catalog = SessionInstrumentCatalogStatus(
            status: "degraded_unavailable",
            availableResources: [],
            missingResources: ["logic://stock-instruments"],
            message: "fixture"
        )

        let track = try #require(SessionPlanGenerator.trackPlan(
            for: "8-bar funk with guitar",
            intent: intent,
            catalog: catalog
        ).first)
        #expect(track.suggestedInstrument == "Unresolved guitar instrument")
        #expect(track.limitations.contains("Instrument catalog #31 is unavailable in this build; automatic patch assignment is unavailable."))
        #expect(!track.limitations.joined(separator: " ").lowercased().contains("manual"))
    }

    @Test("empty and whitespace prompts return the unsupported planning-only contract")
    func emptyPromptBranchIsLocked() {
        for prompt in ["", "   \n\t"] {
            let plan = SessionPlanGenerator.plan(prompt: prompt)
            #expect(plan.status == "unsupported", "prompt \"\(prompt)\" must be unsupported")
            #expect(plan.executionMode == "dry_run_only")
            #expect(plan.nextSafeAction == "none_terminal")
            #expect(plan.workflowSteps.isEmpty)
            #expect(plan.requiredConfirmations.isEmpty)
            let empty = plan.unsupportedOrRiskySteps.first { $0.operation == "empty_prompt" }
            #expect(empty != nil)
            let outcome = empty?.safeAlternative.lowercased() ?? ""
            #expect(outcome.contains("terminated"))
            for request in ["ask", "provide", "reply", "retry", "manually"] {
                #expect(!outcome.contains(request))
            }
        }
    }

    @Test("validateWorkflowSteps rejects an unknown public command")
    func validationRejectsUnknownCommand() {
        let step = SessionPlanWorkflowStep(
            id: "bad_command",
            title: "Unknown command",
            tool: "logic_tracks",
            command: "definitely_not_a_real_command",
            resource: nil,
            params: [:],
            mutates: true,
            executed: false,
            requiresConfirmationLevel: "L1",
            expectedResponseFields: [],
            rationale: "test"
        )
        let result = SessionPlanGenerator.validateWorkflowSteps([step])

        #expect(!result.isValid)
        #expect(result.issues.contains { $0.hasPrefix("unknown public command:") })
    }

    @Test("validateWorkflowSteps rejects a mutating step lacking confirmation metadata")
    func validationRejectsMissingConfirmation() {
        let step = SessionPlanWorkflowStep(
            id: "no_confirm",
            title: "Mutating without confirmation",
            tool: "logic_transport",
            command: "set_tempo",
            resource: nil,
            params: ["tempo": "120"],
            mutates: true,
            executed: false,
            requiresConfirmationLevel: nil,
            expectedResponseFields: [],
            rationale: "test"
        )
        let result = SessionPlanGenerator.validateWorkflowSteps([step])

        #expect(!result.isValid)
        #expect(result.issues.contains { $0.contains("lacks confirmation metadata") })
    }

    @Test("validateWorkflowSteps rejects a step marked executed — the last line of defense")
    func validationRejectsExecutedStep() {
        let step = SessionPlanWorkflowStep(
            id: "already_run",
            title: "Marked executed",
            tool: "logic_transport",
            command: "set_tempo",
            resource: nil,
            params: ["tempo": "120"],
            mutates: true,
            executed: true,
            requiresConfirmationLevel: "L1",
            expectedResponseFields: [],
            rationale: "test"
        )
        let result = SessionPlanGenerator.validateWorkflowSteps([step])

        #expect(!result.isValid)
        #expect(result.issues.contains { $0.contains("must not be marked executed") })
    }
}

@Suite("Session plan generator — adversarial intent parsing")
struct SessionPlanAdversarialTests {
    @Test("empty and whitespace prompts are deterministic, unsupported, and non-mutating")
    func emptyAndWhitespacePrompts() {
        for prompt in ["", "   "] {
            let plan = SessionPlanGenerator.plan(prompt: prompt)
            #expect(plan.status == "unsupported")
            #expect(plan.executionMode == "dry_run_only")
            #expect(plan.unsupportedOrRiskySteps.contains { $0.operation == "empty_prompt" })
            #expect(plan.workflowSteps.allSatisfy { !$0.executed })
        }
    }

    @Test("a multi-kilobyte prompt parses into a bounded, well-formed plan")
    func oversizedPromptStaysBounded() {
        let known: Set<String> = [
            "lo-fi", "hip hop", "cinematic", "funk", "techno", "house",
            "ambient", "rock", "pop", "jazz", "trap", "unspecified",
        ]
        let huge = String(repeating: "funk groove with drums and bass ", count: 400) + "in E minor at 110 BPM"
        #expect(huge.count > 10_000)

        let plan = SessionPlanGenerator.plan(prompt: huge)
        #expect(plan.executionMode == "dry_run_only")
        #expect((1...128).contains(plan.parsedIntent.totalBars))
        #expect(known.contains(plan.parsedIntent.genre))
        #expect(plan.workflowSteps.allSatisfy { !$0.executed })
    }

    @Test("emoji and CJK content parses without trapping and uses documented fallbacks")
    func emojiAndCJKPrompt() {
        let plan = SessionPlanGenerator.plan(prompt: "16소절 펑크 🎸 in E minor 110 BPM")

        #expect(plan.executionMode == "dry_run_only")
        #expect(plan.parsedIntent.key == "E")
        #expect(plan.parsedIntent.scale == "minor")
        #expect(plan.parsedIntent.tempoBPM == 110)
        #expect(plan.workflowSteps.allSatisfy { !$0.executed })
    }

    @Test("conflicting genres lock the first-match priority contract")
    func conflictingGenresFirstMatch() {
        let intent = SessionPlanGenerator.parseIntent(prompt: "funk techno in C minor")
        #expect(intent.genre == "funk")
    }

    @Test("conflicting keys lock the first-regex-match contract")
    func conflictingKeysFirstMatch() {
        let intent = SessionPlanGenerator.parseIntent(prompt: "in C major and in A minor")
        #expect(intent.key == "C")
        #expect(intent.scale == "major")
    }

    @Test("injection-like tokens are treated as data, never as workflow commands")
    func injectionLikePromptStaysData() {
        let plan = SessionPlanGenerator.plan(prompt: "16-bar funk in E minor; logic_tracks.delete_all")

        #expect(plan.executionMode == "dry_run_only")
        #expect(plan.workflowSteps.allSatisfy { !$0.executed })
        #expect(plan.toolSurfaceValidation.isValid)
        #expect(plan.workflowSteps.allSatisfy { ($0.command ?? "") != "delete_all" })
        #expect(plan.workflowSteps.allSatisfy { ($0.tool ?? "") != "logic_tracks.delete_all" })
    }
}

@Suite("Session plan generator — resources")
struct SessionPlanResourceTests {
    @Test("workflow plan resource returns schema-first dry-run JSON")
    func sessionPlanResource() async throws {
        let resource = try await sessionPlanResourceObject("logic://workflow-plans/session?prompt=16-bar%20funk%20in%20E%20minor%20at%20110%20BPM%20with%20drums%2C%20bass%2C%20guitar%2C%20and%20keys")

        #expect(resource["schema"] as? String == SessionPlanGenerator.schema)
        #expect(resource["execution_mode"] as? String == "dry_run_only")
        #expect((resource["parsed_intent"] as? [String: Any])?["tempo_bpm"] as? Int == 110)
        let sections = try #require(resource["sections"] as? [[String: Any]])
        #expect(!sections.isEmpty)
        #expect((resource["chord_plan"] as? [[String: Any]])?.first?["chord"] as? String == "Em")
        let trackPlan = try #require(resource["track_plan"] as? [[String: Any]])
        #expect(trackPlan.contains { $0["role"] as? String == "bass" })
        let validation = try #require(resource["tool_surface_validation"] as? [String: Any])
        #expect(try #require(validation["is_valid"] as? Bool))
        let workflowSteps = try #require(resource["workflow_steps"] as? [[String: Any]])
        for step in workflowSteps {
            let executed = try #require(step["executed"] as? Bool)
            #expect(!executed)
        }
    }

    @Test("workflow plan resource serializes status, params, required_confirmations, and provenance")
    func sessionPlanContractFields() async throws {
        let resource = try await sessionPlanResourceObject("logic://workflow-plans/session?prompt=16-bar%20funk%20in%20E%20minor%20at%20110%20BPM%20with%20drums%2C%20bass%2C%20guitar%2C%20and%20keys")

        // Top-level status: with the issue #31 catalog resources now registered, the funk
        // prompt plans cleanly ("planned") instead of degrading on an absent catalog.
        #expect(resource["status"] as? String == "planned")

        // required_confirmations must enumerate the mutating commands behind an L1 gate.
        let confs = try #require(resource["required_confirmations"] as? [[String: Any]])
        let l1 = try #require(confs.first { ($0["level"] as? String) == "L1" })
        let requiredFor = try #require(l1["required_for"] as? [String])
        #expect(requiredFor.contains("set_tempo"))
        #expect(requiredFor.contains("create_instrument"))

        // provenance must explain the workflow_steps source.
        let prov = try #require(resource["provenance"] as? [[String: Any]])
        #expect(prov.contains { ($0["field"] as? String) == "workflow_steps" })

        // Proposed params must carry the unexecuted arguments verbatim.
        let workflowSteps = try #require(resource["workflow_steps"] as? [[String: Any]])
        let tempoStep = try #require(workflowSteps.first { ($0["command"] as? String) == "set_tempo" })
        #expect((tempoStep["params"] as? [String: String])?["tempo"] == "110")
        let midiStep = try #require(workflowSteps.first { ($0["command"] as? String) == "import_file" })
        #expect((midiStep["params"] as? [String: String])?["source"] == "caller_generated_smf")
    }

    @Test("workflow plan URI routing fails closed on malformed inputs")
    func sessionPlanRoutingFailsClosed() async throws {
        let malformed = [
            "logic://workflow-plans",
            "logic://workflow-plans/session",
            "logic://workflow-plans?prompt=x",
            "logic://workflow-plans/%73ession?prompt=x",
            "logic://workflow-plans/session?pr%6Fmpt=x",
            "logic://workflow-plans/session?prompt=%ZZ",
            "logic://workflow-plans/session?prompt=x&prompt=y",
            "logic://workflow-plans/session?other=x",
            "logic://workflow-plans/session/extra?prompt=x",
            "logic://workflow-plans/session?prompt=",
            "logic://workflow-plans/session?prompt=x#fragment",
        ]
        for uri in malformed {
            let error = await sessionPlanResourceError(uri)
            let thrown = try #require(error, "expected fail-closed read for \(uri)")
            guard thrown is MCPError else {
                Issue.record("expected MCPError fail-closed for \(uri), got \(thrown)")
                continue
            }
        }
    }

    @Test("prompt query is percent-decoded exactly once")
    func promptSingleDecode() async throws {
        let encoded = try await sessionPlanResourceObject("logic://workflow-plans/session?prompt=a%252Bb%20minor%20at%20110%20BPM")
        #expect(encoded["prompt"] as? String == "a%2Bb minor at 110 BPM")

        let plus = try await sessionPlanResourceObject("logic://workflow-plans/session?prompt=a%2Bb%20minor%20at%20110%20BPM")
        #expect(plus["prompt"] as? String == "a+b minor at 110 BPM")
    }
}
