import Foundation
import MCP

/// record_sequence SMF-import implementation, extracted from
/// TrackDispatcher.swift (pure move). handleRecordSequenceSMF generates a
/// Standard MIDI File from the notes spec, imports it via AX menu, and
/// verifies the imported region by AX readback. Helpers stay private to
/// this file; the nested RecordSequenceRegionReadback enum remains in the
/// core TrackDispatcher type.
extension TrackDispatcher {

    // MARK: - record_sequence SMF-import implementation

    /// Generate a Standard MIDI File from the notes spec, write to a private temp dir,
    /// then import into the current project via AX menu navigation. Logic always
    /// creates a NEW MIDI track for the imported content (verified OQ-3).
    static func handleRecordSequenceSMF(
        params: [String: MCP.Value],
        router: ChannelRouter,
        cache: StateCache,
        trackHeaderCount: @escaping @Sendable () -> Int = { AXLogicProElements.allTrackHeaders().count },
        trackNameAt: @escaping @Sendable (Int) -> String? = { AXLogicProElements.trackName(at: $0) },
        readRegions: @escaping @Sendable () -> RecordSequenceRegionReadback = {
            switch AccessibilityChannel.enumerateRegionItems() {
            case .success(let result):
                return .success(result.regions.map { $0.info })
            case .failure(let error):
                return .failure(error.message)
            }
        },
        settleReadback: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 150_000_000) }
    ) async -> CallTool.Result {
        // T5 — record_sequence does not support `port` (no keycmd alternative
        // for SMF-import + AX menu navigation). Reject up-front rather than
        // silently dropping the argument, so a caller who mistakenly thinks
        // `port:"keycmd"` would route this op gets an actionable hint instead
        // of a misleading success at the wrong transport.
        if params["port"] != nil {
            return toolInvalidParamsResult(
                "port parameter not supported for record_sequence"
            )
        }
        let bar: Int
        if params["bar"] != nil {
            guard let parsed = intParamOrNil(params, "bar"),
                  (1...9999).contains(parsed) else {
                return toolInvalidParamsResult(
                    "record_sequence 'bar' must be an integer in 1..9999"
                )
            }
            bar = parsed
        } else {
            bar = 1
        }
        let notes: String
        if let rawNotes = params["notes"] {
            guard let parsed = rawNotes.stringValue, !parsed.isEmpty else {
                return toolInvalidParamsResult(
                    "record_sequence requires 'notes' as a non-empty string"
                )
            }
            notes = parsed
        } else {
            return toolInvalidParamsResult(
                "record_sequence requires 'notes' (semicolon-separated 'pitch,offsetMs,durMs[,vel[,ch]]')"
            )
        }
        let requestedTempo: Double?
        if params["tempo"] != nil {
            guard let parsed = doubleParamOrNil(params, "tempo"), (5.0...999.0).contains(parsed) else {
                return toolInvalidParamsResult(
                    "record_sequence 'tempo' must be numeric in 5..999"
                )
            }
            requestedTempo = parsed
        } else {
            requestedTempo = nil
        }
        guard await cache.getHasDocument() else {
            return toolTextResult("record_sequence: No project open", isError: true)
        }

        let project = await cache.getProject()
        let cacheTempo = project.tempo > 0 ? project.tempo : 120.0
        let tempo = requestedTempo ?? cacheTempo
        // T3 — strict whole-parse-fail. The previous silent-skip parser left
        // callers unable to distinguish "user typed garbage" from "all
        // segments happened to be invalid", so the error wording was vague
        // ("could not parse any valid notes"). The new Result API surfaces
        // the specific failure (channel out of range, malformed segment,
        // etc.) so the LLM agent can self-correct on the next call.
        let events: [SMFWriter.NoteEvent]
        switch parseNotesToSMFEvents(notes: notes, tempo: tempo) {
        case .success(let parsed):
            events = parsed
        case .failure(let error):
            return toolTextResult(
                "record_sequence: invalid 'notes' — \(error.message)",
                isError: true
            )
        }
        guard !events.isEmpty else {
            return toolTextResult(
                "record_sequence: 'notes' parsed to zero events (input: '\(notes)')",
                isError: true
            )
        }
        // v3.1.2 P1-4 — enforce the 1024-note SMF-import upper bound that
        // `NoteSequenceParser`'s docstring already advertises. Without this
        // guard, a malformed (or adversarial) caller could hand SMFWriter an
        // arbitrarily large event list, which would produce an oversize
        // .mid file and slow Logic's MIDI File Import dialog enough to
        // appear hung. The 1024 limit matches the documented upper bound and
        // leaves a comfortable margin under SMFWriter's tick-encoding bounds.
        guard events.count <= 1024 else {
            return toolTextResult(
                "record_sequence: too many notes (\(events.count) > 1024 max for SMF import)",
                isError: true
            )
        }

        let tempFile: SMFWriter.TemporaryMIDIFile
        do {
            tempFile = try SMFWriter.temporaryMIDIFile()
        } catch {
            return toolTextResult("record_sequence: temporary SMF path failed: \(error)", isError: true)
        }
        let path = tempFile.fileURL.path
        defer {
            SMFWriter.cleanupTemporaryMIDIFile(tempFile)
        }

        // Logic's MIDI File import strips leading empty delta before the first
        // channel event (region gets placed at bar 1 regardless of SMF offset).
        // SMFWriter counters this by emitting a padding CC#110 @ tick 0 when
        // bar > 1, so the first note lands at the requested bar inside a
        // region that spans bar 1 → bar+length. The region is cosmetically
        // longer than the notes, but note timing is exact with zero drift.
        do {
            let data = try SMFWriter.generate(
                events: events,
                bar: bar,
                tempo: tempo,
                timeSignature: (4, 4)
            )
            try data.write(to: tempFile.fileURL, options: .atomic)
        } catch {
            return toolTextResult("record_sequence: SMF generation failed: \(error)", isError: true)
        }

        // Logic Pro's MIDI File Import anchors the imported region to the
        // CURRENT playhead position. SMF Strategy D encodes the bar offset
        // inside the file (relative to tick 0), so the playhead must be at
        // bar 1 before import — otherwise notes land at playhead + offset,
        // not at the requested bar. A silent failure here would produce a
        // success response with content at the wrong position, so the goto
        // is a hard precondition: hasDocument is already true (guarded
        // above), so the goto-dialog is enabled on any non-empty project,
        // and on an empty project the playhead is already at bar 1 and the
        // slider fallback succeeds trivially.
        let gotoResult = await router.route(
            operation: "transport.goto_position",
            params: ["bar": "1"]
        )
        guard gotoResult.isSuccess else {
            return toolTextResult(
                "record_sequence failed to reset playhead to bar 1 (required for accurate import): \(gotoResult.message)",
                isError: true
            )
        }

        let preImportRegions: [RegionInfo]?
        switch readRegions() {
        case .success(let regions):
            preImportRegions = regions
        case .failure:
            preImportRegions = nil
        }

        // v3.1.2 (P0-2) — verify track creation against LIVE AX, not the
        // 3-second StatePoller cache. The previous cache-poll loop (2s
        // window, 100ms granularity) was strictly shorter than the poller
        // interval (3s, see ServerConfig.statePollingIntervalNs), so on a
        // healthy import the track count delta would not propagate to
        // `cache.getTracks()` until *after* the verification deadline,
        // false-failing every successful run on first call. Live-witnessed
        // 3× in production sessions.
        //
        // The downstream import handler (AccessibilityChannel
        // `defaultImportMIDIFile`) already validates the count delta against
        // live AX before returning success, so an `importResult.isSuccess`
        // proves a new track was created. We still re-read live track headers
        // here to discover the new track index and then verify the imported
        // region on that specific track.
        let tracksBefore = trackHeaderCount()
        let importResult = await router.route(
            operation: "midi.import_file",
            params: ["path": path]
        )
        guard importResult.isSuccess else {
            // #140 — surface the import handler's dialog-seen flags at the top
            // level (not only buried in `detail`) so callers can distinguish an
            // occluded session (no file-open sheet ever appeared) from a real
            // import miss. The flags originate in
            // `AccessibilityChannel.defaultImportMIDIFile`.
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "error": "import_failure",
                "failure_stage": "midi.import_file",
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "detail": importResult.message,
                "hint": "record_sequence failed at midi.import_file: \(importResult.message)",
            ]
            if let inner = importMessageJSON(importResult.message) {
                for key in ["file_open_dialog_seen", "tempo_dialog_seen", "missing_element"] {
                    if let value = inner[key] { failure[key] = value }
                }
                if let innerError = inner["error"] as? String {
                    failure["import_error"] = innerError
                }
            }
            return jsonToolTextResult(failure, isError: true)
        }

        if let inner = importMessageJSON(importResult.message),
           (inner["verified"] as? Bool) == false {
            let reason = (inner["reason"] as? String) ?? "import_unverified"
            let audibilityDowngrade = reason == HonestContract.UncertainReason.importedAsGMDevice.rawValue
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "error": audibilityDowngrade ? "audibility_unverified" : "import_unverified",
                "failure_stage": "midi.import_file",
                "import_reason": reason,
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "detail": importResult.message,
                "hint": audibilityDowngrade
                    ? "record_sequence imported GM Device / external-MIDI lane(s); region readback cannot prove audible routing, so the take is blocked before a silent Logic Bounce can be claimed."
                    : "record_sequence import returned an unverified State B result; refusing to promote it to a verified take.",
            ]
            for key in [
                "audible",
                "gm_device_lanes",
                "imported_lanes",
                "track_count_before",
                "track_count_after",
                "observed_delta",
                "file_open_dialog_seen",
                "tempo_dialog_seen",
            ] {
                if let value = inner[key] { failure[key] = value }
            }
            return jsonToolTextResult(failure, isError: true)
        }

        // Re-read live AX to confirm the new track index. Import handler has
        // already verified the delta, so we expect tracksAfter > tracksBefore
        // immediately; the small retry loop is purely defensive against AX
        // tree settle latency on slow machines (≤500ms total).
        var tracksAfter = trackHeaderCount()
        for _ in 0..<5 {
            if tracksAfter > tracksBefore { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            tracksAfter = trackHeaderCount()
        }
        guard tracksAfter > tracksBefore else {
            return jsonToolTextResult([
                "success": false,
                "verified": false,
                "error": "import_failure",
                "failure_stage": "track_creation",
                "bar": bar,
                "note_count": events.count,
                "method": "smf_import",
                "track_count_before": tracksBefore,
                "track_count_after": tracksAfter,
                "hint": "record_sequence: import handler reported success but live AX still shows \(tracksBefore) tracks (no delta within 500ms). Check Logic Pro UI and retry.",
            ], isError: true)
        }

        let createdTrack = tracksAfter - 1

        // v3.0.8 — instrument auto-load has been REMOVED from record_sequence.
        //
        // Prior versions (v3.0.2 – v3.0.7) auto-routed `track.set_instrument`
        // on the just-created track, defaulted `instrument_path` to
        // `"Synthesizer/Bass"`, and reported `"instrument":"loaded:..."` based
        // on `setResult.isSuccess`. Live testing on v3.0.7 + v3.0.8-draft
        // revealed two compounding bugs that made that path untrustworthy:
        //
        //   1. `LibraryAccessor.selectPath`'s AXPress on the preset leaf
        //      returns `.success` when the AX action is *delivered*, not when
        //      Logic's handler actually swaps the channel-strip instrument.
        //      `selectCategory` unconditionally returns `true` once the
        //      AXStaticText element is found, whether or not the AX write
        //      committed.
        //   2. `AXLogicProElements.selectTrackViaAX(at:)` is silently unable
        //      to change selection on a freshly-created track header on the
        //      first run-loop tick after SMF import. AXPress, AXSelected,
        //      child AXPress, and coord-click ALL get dropped; the header is
        //      visible in the AX tree and `findTrackHeader` resolves it, but
        //      selection never moves off the previously-selected track. The
        //      downstream `selectPath` then loads the preset onto whichever
        //      track was already selected — which can CORRUPT a pre-existing
        //      track's patch. Observed live: `record_sequence` with
        //      `instrument_path: "Electronic Drums/Brooklyn Borough"` on a
        //      project with a pre-existing `Deluxe Classic` (Electric Piano)
        //      track silently replaced `Deluxe Classic`'s patch with the
        //      Brooklyn Borough drum kit, while the new MIDI-imported track
        //      kept its default `Studio Grand` piano.
        //
        // v3.0.9 note — the `selectTrackViaAX` primitive itself is now fixed
        // (switched to AXSelectedChildren on the parent "Tracks header" group,
        // which is what Library preset selection already used). Callers of
        // `track.set_instrument { index: N }` now consistently target track N.
        // The record_sequence internal auto-load is STILL removed, however:
        // bundling two separate live Logic ops inside one dispatcher call
        // creates ordering dependencies that are hard to reason about, and
        // Isaac's policy on this ("decouple") stands. Callers who want a
        // specific patch after `record_sequence` should call `track.select`
        // + `track.set_instrument` explicitly on the returned track index.
        let instrumentPath = stringParam(params, "instrument_path", "instrument")
        let instrumentStatus: String
        if instrumentPath.isEmpty {
            instrumentStatus = "not-attempted"
        } else {
            instrumentStatus = "ignored:\(instrumentPath) (v3.0.8: internal auto-load removed to prevent corrupting a pre-existing track — call set_instrument explicitly; see CHANGELOG v3.0.8 for the selectTrackViaAX limitation on fresh SMF-created tracks)"
        }

        return await verifyRecordSequenceImport(
            createdTrack: createdTrack,
            targetTrackName: trackNameAt(createdTrack),
            requestedBar: bar,
            noteCount: events.count,
            instrumentStatus: instrumentStatus,
            events: events,
            preImportRegions: preImportRegions,
            readRegions: readRegions,
            settleReadback: settleReadback
        )
    }

    private enum RecordSequenceReadbackStatus {
        case verified([String: Any])
        case failed([String: Any])
        case pending
    }

    /// Parse the `midi.import_file` envelope (a JSON string carried in
    /// `ChannelResult.message`) so record_sequence can lift specific fields
    /// (e.g. #140 dialog-seen flags) to its own top-level envelope. Returns nil
    /// for non-JSON/free-form messages.
    private static func importMessageJSON(_ message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func jsonToolTextResult(_ object: [String: Any], isError: Bool = false) -> CallTool.Result {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return toolTextResult("record_sequence: failed to encode JSON response", isError: true)
        }
        return toolTextResult(text, isError: isError)
    }

    private static func verifyRecordSequenceImport(
        createdTrack: Int,
        targetTrackName: String?,
        requestedBar: Int,
        noteCount: Int,
        instrumentStatus: String,
        events: [SMFWriter.NoteEvent],
        preImportRegions: [RegionInfo]?,
        readRegions: @escaping @Sendable () -> RecordSequenceRegionReadback,
        settleReadback: @escaping @Sendable () async -> Void
    ) async -> CallTool.Result {
        let expectedStartBar = 1
        let expectedEndBar = recordSequenceExpectedEndBar(for: events, requestedBar: requestedBar)
        let base: [String: Any] = [
            "bar": requestedBar,
            "created_track": createdTrack,
            "recorded_to_track": createdTrack,
            "target_track_index": createdTrack,
            "target_track_name": targetTrackName ?? "",
            "note_count": noteCount,
            "method": "smf_import",
            "instrument": instrumentStatus,
            "expected_start_bar": expectedStartBar,
            "expected_end_bar": expectedEndBar,
        ]
        let preRegionKeys = Set((preImportRegions ?? []).map(recordSequenceRegionKey))
        let hasPreImportSnapshot = preImportRegions != nil
        let verifySource = hasPreImportSnapshot ? "ax_region_delta" : "ax_region_readback"

        var bestFailure: [String: Any]?
        var lastReadbackError: String?
        var lastRegionCount = 0
        var lastNewRegionCount = 0

        for attempt in 0..<10 {
            switch readRegions() {
            case .failure(let error):
                lastReadbackError = error
            case .success(let regions):
                lastRegionCount = regions.count
                lastNewRegionCount = hasPreImportSnapshot
                    ? regions.filter { !preRegionKeys.contains(recordSequenceRegionKey($0)) }.count
                    : 0

                switch diagnoseRecordSequenceReadback(
                    postImportRegions: regions,
                    hasPreImportSnapshot: hasPreImportSnapshot,
                    preImportRegionKeys: preRegionKeys,
                    createdTrack: createdTrack,
                    expectedStartBar: expectedStartBar,
                    expectedEndBar: expectedEndBar,
                    base: base,
                    verifySource: verifySource
                ) {
                case .verified(let payload):
                    return jsonToolTextResult(payload)
                case .failed(let payload):
                    if shouldPreferRecordSequenceFailure(candidate: payload, over: bestFailure) {
                        bestFailure = payload
                    }
                case .pending:
                    break
                }
            }

            if attempt < 9 {
                await settleReadback()
            }
        }

        if var bestFailure {
            bestFailure["region_count"] = lastRegionCount
            bestFailure["new_region_count"] = lastNewRegionCount
            if let lastReadbackError {
                bestFailure["readback_error"] = lastReadbackError
            }
            return jsonToolTextResult(bestFailure, isError: true)
        }

        var payload = base
        payload["success"] = false
        payload["verified"] = false
        payload["error"] = "unreadable_readback"
        payload["verify_source"] = verifySource
        payload["region_count"] = lastRegionCount
        payload["new_region_count"] = lastNewRegionCount
        payload["hint"] = lastReadbackError.map {
            "record_sequence region readback failed: \($0)"
        } ?? "record_sequence imported a new track but no MIDI region could be verified from AX readback"
        if let lastReadbackError {
            payload["readback_error"] = lastReadbackError
        }
        return jsonToolTextResult(payload, isError: true)
    }

    private static func diagnoseRecordSequenceReadback(
        postImportRegions: [RegionInfo],
        hasPreImportSnapshot: Bool,
        preImportRegionKeys: Set<String>,
        createdTrack: Int,
        expectedStartBar: Int,
        expectedEndBar: Int,
        base: [String: Any],
        verifySource: String
    ) -> RecordSequenceReadbackStatus {
        let newRegions = hasPreImportSnapshot
            ? postImportRegions.filter { !preImportRegionKeys.contains(recordSequenceRegionKey($0)) }
            : []
        let targetRegions = postImportRegions.filter { $0.trackIndex == createdTrack }

        if let targetRegion = preferredRecordSequenceRegion(from: targetRegions) {
            var payload = base
            payload["verify_source"] = verifySource
            for (key, value) in recordSequenceRegionFields(targetRegion) {
                payload[key] = value
            }
            if targetRegion.startBar < 0 || targetRegion.endBar < 0 {
                payload["success"] = false
                payload["verified"] = false
                payload["error"] = "unreadable_readback"
                payload["hint"] = "record_sequence found a region on the created track, but AX did not expose readable start/end bars"
                return .failed(payload)
            }
            if targetRegion.startBar == expectedStartBar && targetRegion.endBar == expectedEndBar {
                payload["success"] = true
                payload["verified"] = true
                return .verified(payload)
            }
            payload["success"] = false
            payload["verified"] = false
            payload["error"] = "timing_mismatch"
            payload["hint"] = "record_sequence region readback did not match the expected bar envelope"
            return .failed(payload)
        }

        if let wrongTrackRegion = preferredRecordSequenceRegion(from: newRegions.filter { $0.trackIndex >= 0 && $0.trackIndex != createdTrack }) {
            var payload = base
            payload["success"] = false
            payload["verified"] = false
            payload["error"] = "wrong_track_import"
            payload["verify_source"] = verifySource
            payload["hint"] = "record_sequence imported a region, but AX readback placed it on track \(wrongTrackRegion.trackIndex) instead of the newly created track \(createdTrack)"
            for (key, value) in recordSequenceRegionFields(wrongTrackRegion, prefix: "observed_") {
                payload[key] = value
            }
            return .failed(payload)
        }

        if postImportRegions.isEmpty {
            return .pending
        }

        var payload = base
        payload["success"] = false
        payload["verified"] = false
        payload["error"] = "unreadable_readback"
        payload["verify_source"] = verifySource
        payload["hint"] = "record_sequence imported a new track but no MIDI region could be verified on the created track"
        return .failed(payload)
    }

    private static func shouldPreferRecordSequenceFailure(
        candidate: [String: Any],
        over current: [String: Any]?
    ) -> Bool {
        guard let current else { return true }
        return recordSequenceFailurePriority(candidate) > recordSequenceFailurePriority(current)
    }

    private static func recordSequenceFailurePriority(_ payload: [String: Any]) -> Int {
        switch payload["error"] as? String {
        case "wrong_track_import":
            return 3
        case "timing_mismatch":
            return 2
        case "unreadable_readback":
            return 1
        default:
            return 0
        }
    }

    private static func recordSequenceExpectedEndBar(
        for events: [SMFWriter.NoteEvent],
        requestedBar: Int,
        timeSignatureNumerator: Int = 4,
        ticksPerQuarter: Int = 480
    ) -> Int {
        let ticksPerBar = timeSignatureNumerator * ticksPerQuarter
        let maxEndTicks = events.map { $0.offsetTicks + $0.durationTicks }.max() ?? 0
        let absoluteEndTicks = maxEndTicks + max(0, requestedBar - 1) * ticksPerBar
        return max(2, (absoluteEndTicks / ticksPerBar) + 2)
    }

    private static func recordSequenceRegionKey(_ region: RegionInfo) -> String {
        [
            region.name,
            String(region.trackIndex),
            String(region.startBar),
            String(region.endBar),
            region.kind,
        ].joined(separator: "|")
    }

    private static func preferredRecordSequenceRegion(from regions: [RegionInfo]) -> RegionInfo? {
        regions.max { lhs, rhs in
            if lhs.trackIndex != rhs.trackIndex { return lhs.trackIndex < rhs.trackIndex }
            if lhs.endBar != rhs.endBar { return lhs.endBar < rhs.endBar }
            if lhs.startBar != rhs.startBar { return lhs.startBar < rhs.startBar }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func recordSequenceRegionFields(
        _ region: RegionInfo,
        prefix: String = ""
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "\(prefix)region_name": region.name,
            "\(prefix)start_bar": region.startBar,
            "\(prefix)end_bar": region.endBar,
            "\(prefix)region_kind": region.kind,
        ]
        if !prefix.isEmpty {
            payload["\(prefix)track_index"] = region.trackIndex
        }
        if let rawHelp = region.rawHelp, !rawHelp.isEmpty {
            payload["\(prefix)raw_help"] = rawHelp
        }
        return payload
    }

    private static func parseNotesToSMFEvents(
        notes: String,
        tempo: Double
    ) -> Result<[SMFWriter.NoteEvent], RecordSequenceNoteValidationError> {
        switch NoteSequenceParser.parse(notes) {
        case .failure(let error):
            return .failure(RecordSequenceNoteValidationError(message: error.hint))
        case .success(let parsed):
            if let violation = NoteSequenceParser.smfTimingViolation(in: parsed) {
                return .failure(RecordSequenceNoteValidationError(message: violation))
            }
            return .success(parsed.map { note in
                let ticks = SMFWriter.msToTicks(
                    offsetMs: note.offsetMs,
                    durationMs: note.durationMs,
                    tempo: tempo
                )
                return SMFWriter.NoteEvent(
                    pitch: note.pitch,
                    offsetTicks: ticks.offsetTicks,
                    durationTicks: ticks.durationTicks,
                    velocity: note.velocity,
                    channel: note.channel
                )
            })
        }
    }

    private struct RecordSequenceNoteValidationError: Error {
        let message: String
    }

}
